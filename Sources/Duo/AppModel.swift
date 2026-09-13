import AppKit
import Combine
import IOKit.ps
import Metal
import OSLog
import ScreenCaptureKit

/// `log stream --predicate 'subsystem == "com.toby.duo"' --level info` follows the app live.
let duoLog = Logger(subsystem: "com.toby.duo", category: "app")

/// Owns everything: sensor → lid model → capture / renderer / overlay, plus sleep, display,
/// power and preview handling. Lives entirely on the main actor.
@MainActor final class AppModel: ObservableObject {
    // Published for the Settings window and menu. The fast-changing ones are throttled to
    // 10 Hz and only while something is actually looking (`liveObservers > 0`).
    @Published private(set) var lidAngle: Double?
    @Published private(set) var statusLine = "Starting…"
    @Published private(set) var sensorAvailable = false
    @Published private(set) var sensorStatus = "Looking for the lid sensor…"
    @Published private(set) var hasScreenRecording = ScreenCapture.hasPermission
    @Published private(set) var isPreviewing = false
    @Published private(set) var lastError: String?

    let prefs: Preferences
    let sensor = LidSensor()
    let model = LidModel()
    let capture = ScreenCapture()

    /// Always current, unlike the throttled `lidAngle`.
    private(set) var currentAngle: Double?
    /// Menus and windows showing live values bump this while they are open.
    var liveObservers = 0 {
        didSet { if liveObservers > 0 { publishLive(force: true) } }
    }

    private static let captureGracePeriod: TimeInterval = 3
    private static let previewDuration: TimeInterval = 4
    private static let captureRetryDelay: TimeInterval = 5
    /// Opening reveal: the desktop swings up from this far folded (degrees below "Reveal by")
    /// over `revealDuration`, then the ordinary clear hands the real desktop back.
    private static let revealStartDelta = 42.0
    private static let revealEndDelta = 2.5
    private static let revealDuration: TimeInterval = 0.55
    /// An armed reveal that never gets its unlock (or display) gives up after this long.
    private static let revealArmTimeout: TimeInterval = 45
    /// A closing lid this far below its resting angle starts the capture stream before the
    /// 1° engage deadband is crossed, so the first frame is ready the moment it engages.
    private static let prewarmDelta = 0.45
    /// No sensor readings for this long means the process was frozen: the Mac was asleep and
    /// is waking now — well before `didWakeNotification` arrives.
    private static let wakeGap: TimeInterval = 1.0

    private var renderer: Renderer?
    private var overlay: OverlayWindow?
    private var overlayShown = false
    private var overlayRevealed = false
    private var captureGrace: Timer?
    private var captureFailedAt: TimeInterval = -.infinity
    private var captureFPS = 60
    private var previewStart: TimeInterval?
    private var systemAsleep = false
    private var screensAsleep = false
    /// A wake notification arrived; play the "opening after sleep" reveal once the model can run.
    private var wakeRevealPending = false
    /// The reveal is pre-warmed (overlay + capture alive, nothing drawn) and waiting for the
    /// desktop to become visible — normally the screen unlock.
    private var revealArmed = false
    private var revealArmedAt: TimeInterval = 0
    /// A synthetic reveal is playing from this folded state (nil while the lid drives it).
    private var revealSeed: FoldState?
    private var revealStart: TimeInterval?
    private var lastRevealLockCheck: TimeInterval = 0
    private var screenLocked = false
    private var lastReadingAt: TimeInterval?
    /// When the current wake began (sensor gap or notification); later notifications for the
    /// same wake must not start a second reveal.
    private var lastWakeAt: TimeInterval = -.infinity
    private static let wakeDebounce: TimeInterval = 10
    private var distributedObservers: [NSObjectProtocol] = []
    private var activity: NSObjectProtocol?
    private var displayID: CGDirectDisplayID?
    private var permissionRequested = false
    private var lastPublish: TimeInterval = 0
    private var lastPhase: LidModel.Phase = .idle
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()

    init(prefs: Preferences) {
        self.prefs = prefs
        model.clearsAt = prefs.clearsAt

        sensor.onReading = { [weak self] angle in self?.handleReading(angle) }
        sensor.onGap = { [weak self] gap in self?.sensorGap(gap) }
        sensor.onStatus = { [weak self] text in
            duoLog.info("sensor: \(text, privacy: .public)")
            self?.sensorStatus = text
        }
        model.onChange = { [weak self] _ in self?.modelChanged() }
        capture.onFirstFrame = { [weak self] in
            guard let self else { return }
            // A complete frame means capture recovered; drop any stale "Capture failed/stopped" line.
            lastError = nil
            publishLive(force: true)
        }
        capture.onStopped = { [weak self] error in self?.captureStopped(error) }

        prefs.$clearsAt.dropFirst().sink { [weak self] value in self?.model.clearsAt = value }.store(in: &subscriptions)
        // `@Published` emits from `willSet`; hop to the next main-queue turn so `prefs.enabled`
        // has settled before `shouldRun`, `updatePacing()` and `describeState()` re-read it.
        prefs.$enabled.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.enabledChanged() }
            .store(in: &subscriptions)
        Publishers.CombineLatest3(prefs.$perspective, prefs.$blur, prefs.$shadow)
            .sink { [weak self] p, b, s in
                self?.renderer?.appearance = Appearance(perspective: Float(p), blur: Float(b), shadow: Float(s))
            }
            .store(in: &subscriptions)

        observeSystem()
        screenLocked = Self.isScreenLocked()
        displayID = builtInScreen()?.displayID
        reconcileSuspension()
        updatePacing()
        updateActivity()
        sensor.start()

        if prefs.enabled && !hasScreenRecording {
            // Ask once, a moment after launch, so the prompt is not the first thing on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.promptForPermissionOnce() }
        }
    }

    // MARK: Public actions

    /// Plays the opening reveal now, as if the Mac had just woken (`duo://reveal`).
    func startReveal() {
        guard shouldRun, previewStart == nil, revealSeed == nil else { return }
        cancelReveal()
        wakeRevealPending = true
        reconcileSuspension()
    }

    /// One line for `duo://status` and the log.
    func logStatus() {
        let angle = currentAngle.map { String(format: "%.2f°", $0) } ?? "no sensor"
        let ref = model.reference.map { String(format: "%.2f°", $0) } ?? "—"
        duoLog.info("status: \(self.statusLine, privacy: .public) | angle \(angle, privacy: .public) reference \(ref, privacy: .public) phase \(String(describing: self.model.phase), privacy: .public) still=\(self.model.isStill) enabled=\(self.prefs.enabled) permission=\(self.hasScreenRecording) capture=\(self.capture.isRunning) overlay=\(self.overlayShown)/\(self.overlayRevealed) preview=\(self.isPreviewing) revealArmed=\(self.revealArmed) revealing=\(self.revealSeed != nil) locked=\(self.screenLocked)")
    }

    var builtInDisplayActive: Bool { builtInScreen() != nil }

    /// Plays a synthetic close → open over a few seconds without moving the lid.
    func startPreview() {
        guard previewStart == nil, shouldRun else { return }
        refreshPermission()
        guard hasScreenRecording else { requestPermissionIfNeeded(); return }
        previewStart = ProcessInfo.processInfo.systemUptime
        isPreviewing = true
        lastError = nil
        duoLog.info("preview started")
        syncOverlay()
        updatePacing()
        publishLive(force: true)
    }

    func refreshPermission() {
        let granted = ScreenCapture.hasPermission
        if granted != hasScreenRecording {
            duoLog.info("screen recording permission: \(granted ? "granted" : "missing", privacy: .public)")
            hasScreenRecording = granted
            if granted { lastError = nil; captureFailedAt = -.infinity }
        }
    }

    /// Menu action: prompt if macOS still allows it, otherwise open the Privacy pane.
    func requestPermissionIfNeeded() {
        refreshPermission()
        guard !hasScreenRecording else { return }
        if permissionRequested {
            // macOS only prompts once per process; send the user to the Privacy pane instead.
            ScreenCapture.openPrivacySettings()
        } else {
            promptForPermissionOnce()
        }
    }

    /// Shows the system prompt at most once per launch; never opens System Settings by itself.
    private func promptForPermissionOnce() {
        refreshPermission()
        guard !hasScreenRecording, !permissionRequested else { return }
        permissionRequested = true
        duoLog.info("requesting screen recording permission")
        ScreenCapture.requestPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermission() }
    }

    func shutdown() {
        hideOverlayNow()
        stopCapture(immediately: true)
        sensor.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        observers.removeAll()
    }

    // MARK: Sensor → model

    private func handleReading(_ angle: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = lastReadingAt.map { now - $0 } ?? 0
        lastReadingAt = now
        currentAngle = angle
        if sensorAvailable != (angle != nil) {
            sensorAvailable = angle != nil
            publishLive(force: true)
        }

        // Backup for `sensorGap`: a gap seen on the reading side while still marked asleep.
        if systemAsleep, gap > Self.wakeGap { sensorGap(gap) }

        model.observe(angle: angle, at: now)

        if wakeRevealPending || revealArmed {
            pollReveal(at: now)
        } else if let angle, prefs.enabled, hasScreenRecording, previewStart == nil, revealSeed == nil,
                  model.phase == .idle, let reference = model.reference,
                  angle < reference - Self.prewarmDelta, !model.isClosed {
            prewarmCapture()
        }
        if liveObservers > 0 { publishLive() }
    }

    /// The sensor's poll timer skipped: the process was frozen for sleep and is running again.
    /// This lands well before macOS's own wake notification.
    private func sensorGap(_ gap: TimeInterval) {
        guard systemAsleep else { return }
        duoLog.info("early wake from sensor gap (\(gap, format: .fixed(precision: 2)) s) angle=\(self.currentAngle ?? -1, privacy: .public)")
        systemAsleep = false
        screensAsleep = false
        lastWakeAt = -.infinity
        wake()
    }

    private func modelChanged() {
        // The renderer pulls `model.target` itself every frame; only phase changes need work here.
        let phaseChanged = model.phase != lastPhase
        lastPhase = model.phase
        if phaseChanged {
            let angle = currentAngle.map { String(format: "%.2f", $0) } ?? "nil"
            let ref = model.reference.map { String(format: "%.2f", $0) } ?? "nil"
            duoLog.info("phase → \(String(describing: self.model.phase), privacy: .public) angle=\(angle, privacy: .public) reference=\(ref, privacy: .public)")
            updatePacing()
            syncOverlay()
        }
        if phaseChanged || liveObservers > 0 { publishLive(force: phaseChanged) }
    }

    // MARK: Overlay lifecycle

    private var shouldRun: Bool {
        prefs.enabled && !systemAsleep && !screensAsleep && builtInScreen() != nil
    }

    /// Brings the overlay/capture in line with what the model (or a preview) wants.
    private func syncOverlay() {
        let wants = shouldRun && (model.wantsOverlay || previewStart != nil || revealArmed || revealSeed != nil)
        guard wants else {
            if overlayShown { hideOverlayNow() }
            if capture.isRunning { stopCapture(immediately: !shouldRun) }
            return
        }
        guard let screen = builtInScreen() else { return }
        refreshPermission()
        guard hasScreenRecording else {
            promptForPermissionOnce()
            // No overlay means no clear animation to wait for: let the model settle now.
            model.didFinishClear()
            cancelPreview()
            cancelReveal()
            return
        }
        do {
            try ensureOverlay(on: screen)
        } catch {
            report(error.localizedDescription)
            model.didFinishClear()
            cancelPreview()
            cancelReveal()
            return
        }
        captureGrace?.invalidate()
        captureGrace = nil
        startCaptureIfNeeded(on: screen)
        if revealArmed {
            // Pre-warmed and waiting for the desktop to become visible: keep the panel ordered
            // in at alpha 0 with nothing drawn, so `playReveal()` can present its first frame
            // the instant the unlock lands.
            if !overlayShown {
                overlayShown = true
                overlayRevealed = false
                overlay?.show()
            }
            return
        }
        if !overlayShown {
            overlayShown = true
            overlayRevealed = false
            renderer?.begin()
            overlay?.show()
            duoLog.info("overlay shown (alpha 0, waiting for first frame)")
        } else if renderer?.isActive == false {
            renderer?.begin()
        }
    }

    private func ensureOverlay(on screen: NSScreen) throws {
        if let overlay { overlay.fit(to: screen); return }
        guard let device = MTLCreateSystemDefaultDevice() else { throw DuoError.message("Metal is unavailable on this Mac.") }
        let renderer = try Renderer(device: device)
        renderer.frames = capture.frames
        renderer.appearance = Appearance(perspective: Float(prefs.perspective), blur: Float(prefs.blur), shadow: Float(prefs.shadow))
        renderer.targetProvider = { [weak self] now in
            guard let self else { return .clear }
            if let preview = self.previewTarget(at: now) { return preview }
            // A lid that starts closing during the reveal takes over immediately.
            if self.model.isEngaged { self.cancelReveal(); return self.model.target }
            return self.revealTarget(at: now) ?? self.model.target
        }
        renderer.onFirstPresented = { [weak self] in self?.revealOverlay() }
        renderer.onCoverage = { [weak self] coverage in
            guard let self, self.overlayRevealed else { return }
            self.overlay?.alphaValue = CGFloat(coverage)
        }
        renderer.onClearSettled = { [weak self] in self?.overlayDidClear() }
        renderer.onFailure = { [weak self] reason in self?.report(reason) }
        let overlay = OverlayWindow(screen: screen, contentView: renderer.view)
        self.renderer = renderer
        self.overlay = overlay
        updatePacing()
    }

    private func revealOverlay() {
        guard overlayShown, let renderer, let overlay else { return }
        overlayRevealed = true
        overlay.alphaValue = CGFloat(renderer.coverage)
        duoLog.info("overlay revealed: first frame presented, coverage=\(renderer.coverage, privacy: .public)")
    }

    /// The clear animation reached zero: hand the screen back and release the frame.
    private func overlayDidClear() {
        hideOverlayNow()
        if model.wantsOverlay || previewStart != nil {
            // The lid moved again during the hand-off; pick straight back up.
            syncOverlay()
        } else {
            stopCapture(immediately: false)
        }
    }

    private func hideOverlayNow() {
        if overlayShown { duoLog.info("overlay hidden") }
        overlay?.hide()
        renderer?.stop()
        overlayShown = false
        overlayRevealed = false
        model.didFinishClear()
        cancelPreview()
        cancelReveal()
    }

    /// The overlay is gone (clear finished, suspended, capture failed, display changed): any
    /// preview is over. A forced hide stops the render loop that would otherwise end the preview
    /// via `previewTarget(at:)`, so end it here or the status line, the Preview menu item and the
    /// sensor poll rate stay stuck on "Previewing…".
    private func cancelPreview() {
        guard previewStart != nil else { return }
        previewStart = nil
        isPreviewing = false
        updatePacing()
        publishLive(force: true)
    }

    // MARK: Capture

    private func startCaptureIfNeeded(on screen: NSScreen) {
        guard !capture.isRunning, let id = screen.displayID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - captureFailedAt > Self.captureRetryDelay else { return }
        let scale = screen.backingScaleFactor
        let pixelSize = CGSize(width: (screen.frame.width * scale).rounded(), height: (screen.frame.height * scale).rounded())
        let fps = captureFPS
        Task { [weak self] in
            guard let self else { return }
            do {
                duoLog.info("capture starting: display \(id) \(Int(pixelSize.width))×\(Int(pixelSize.height)) @\(fps) Hz")
                try await self.capture.start(displayID: id, pixelSize: pixelSize, fps: fps)
            } catch {
                self.captureFailed(error)
            }
        }
    }

    private func captureFailed(_ error: Error) {
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain, failure.code == SCStreamError.Code.userDeclined.rawValue {
            hasScreenRecording = false
            report("Screen Recording permission is required.")
        } else {
            report("Capture failed: \(error.localizedDescription)")
        }
        captureDidFail()
    }

    private func captureStopped(_ error: Error?) {
        if let error { report("Capture stopped: \(error.localizedDescription)") }
        refreshPermission()
        captureDidFail()
    }

    /// Hide, back off, and try again later if the lid still wants the effect.
    private func captureDidFail() {
        captureFailedAt = ProcessInfo.processInfo.systemUptime
        hideOverlayNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureRetryDelay + 0.1) { [weak self] in
            guard let self, self.model.wantsOverlay || self.previewStart != nil else { return }
            self.syncOverlay()
        }
    }

    /// Stops the stream now, or after a short grace period so a quick re-open is instant.
    private func stopCapture(immediately: Bool) {
        captureGrace?.invalidate()
        captureGrace = nil
        guard capture.isRunning else { return }
        if immediately {
            duoLog.info("capture stopped")
            capture.stop()
            return
        }
        captureGrace = Timer.scheduledTimer(withTimeInterval: Self.captureGracePeriod, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureGrace = nil
                if !self.overlayShown { duoLog.info("capture stopped after grace period"); self.capture.stop() }
            }
        }
    }

    private func report(_ message: String) {
        duoLog.error("\(message, privacy: .public)")
        lastError = message
        publishLive(force: true)
    }

    // MARK: Preview

    private func previewTarget(at now: TimeInterval) -> FoldState? {
        guard let start = previewStart else { return nil }
        let t = now - start
        guard t < Self.previewDuration else {
            cancelPreview()
            return nil
        }
        let reference = prefs.clearsAt
        let maxDelta = min(75, reference - 8)
        // sin² sweep: stationary at both ends, deepest half-way through.
        let s = sin(.pi * t / Self.previewDuration)
        let delta = max(0.75, maxDelta * s * s)
        return FoldState.at(angle: reference - delta, reference: reference)
    }

    // MARK: Opening reveal

    /// Wake (or the built-in display coming back) with the model able to run: get everything
    /// ready without drawing, then play as soon as the desktop is actually visible.
    private func armReveal() {
        guard prefs.enabled, hasScreenRecording, !revealArmed, revealSeed == nil, previewStart == nil,
              let screen = builtInScreen() else { return }
        do { try ensureOverlay(on: screen) } catch { report(error.localizedDescription); return }
        revealArmed = true
        revealArmedAt = ProcessInfo.processInfo.systemUptime
        screenLocked = Self.isScreenLocked()
        duoLog.info("reveal armed: pre-warming capture, screen \(self.screenLocked ? "locked" : "unlocked", privacy: .public)")
        syncOverlay()
        if !screenLocked { playReveal() }
    }

    /// While armed: give up after a while, and catch an unlock whose notification was missed.
    private func pollReveal(at now: TimeInterval) {
        if wakeRevealPending, !revealArmed, shouldRun {
            // The display came online between notifications; `reconcileSuspension` will arm.
            reconcileSuspension()
        }
        guard revealArmed else { return }
        if now - revealArmedAt > Self.revealArmTimeout {
            duoLog.info("reveal gave up waiting for the desktop")
            cancelReveal()
            syncOverlay()
            return
        }
        if now - lastRevealLockCheck > 0.5 {
            lastRevealLockCheck = now
            let locked = Self.isScreenLocked()
            if locked != screenLocked { screenLocked = locked }
            if !locked { playReveal() }
        }
    }

    /// The desktop is visible: swing it into focus. If the lid is genuinely still rising the
    /// model drives it from its real angle; otherwise a synthetic opening plays.
    private func playReveal() {
        guard revealArmed else { return }
        revealArmed = false
        guard shouldRun, let renderer, overlayShown else { cancelReveal(); syncOverlay(); return }
        let seed: FoldState
        if model.isEngaged {
            seed = model.target
            duoLog.info("reveal: lid still opening at \(self.currentAngle ?? -1, privacy: .public)°, following it")
        } else {
            let reference = prefs.clearsAt
            seed = FoldState.at(angle: reference - Self.revealStartDelta, reference: reference)
            revealSeed = seed
            revealStart = nil
            duoLog.info("reveal: lid already open, playing the opening from Δ\(Self.revealStartDelta, privacy: .public)°")
        }
        overlayRevealed = false
        renderer.begin(seed: seed)
        updatePacing()
        publishLive(force: true)
    }

    private func revealTarget(at now: TimeInterval) -> FoldState? {
        guard let seed = revealSeed else { return nil }
        guard let start = revealStart else {
            // Hold the folded pose until a captured frame exists; the clock starts on the first.
            guard capture.frames.latest() != nil else { return seed }
            revealStart = now
            return seed
        }
        let t = min(1, (now - start) / Self.revealDuration)
        if t >= 1 {
            cancelReveal()
            return nil  // .clear from the model: the ordinary clear finishes the hand-off.
        }
        // Ease-out cubic: fast off the hinge, settling as it approaches open.
        let swing = 1 - pow(1 - t, 3)
        let delta = Self.revealStartDelta + (Self.revealEndDelta - Self.revealStartDelta) * swing
        return FoldState.at(angle: seed.referenceAngle - delta, reference: seed.referenceAngle)
    }

    private func cancelReveal() {
        let was = revealArmed || revealSeed != nil
        revealArmed = false
        revealSeed = nil
        revealStart = nil
        if was { updatePacing(); publishLive(force: true) }
    }

    /// Closing has begun (below the pre-warm band but above the engage deadband): start the
    /// stream now so it has a frame by the time the effect engages. The grace timer stops it
    /// again if the lid settles without engaging.
    private func prewarmCapture() {
        guard !capture.isRunning, let screen = builtInScreen() else {
            armCaptureGrace()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - captureFailedAt > Self.captureRetryDelay else { return }
        do { try ensureOverlay(on: screen) } catch { return }
        duoLog.info("pre-warming capture: lid moving at \(self.currentAngle ?? -1, privacy: .public)°")
        startCaptureIfNeeded(on: screen)
        armCaptureGrace()
    }

    private func armCaptureGrace() {
        captureGrace?.invalidate()
        captureGrace = Timer.scheduledTimer(withTimeInterval: Self.captureGracePeriod, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureGrace = nil
                if !self.overlayShown, self.capture.isRunning { duoLog.info("capture stopped after grace period"); self.capture.stop() }
            }
        }
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Menu-bar apps get App Nap'd; a napped timer would miss the lid's first degrees.
    private func updateActivity() {
        if prefs.enabled {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                 reason: "Following the lid angle")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: Pacing

    private func updatePacing() {
        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let lowPower = info.isLowPowerModeEnabled
        let maxFPS = builtInScreen()?.maximumFramesPerSecond ?? 60
        let fps = hot ? 30 : (lowPower ? min(60, maxFPS) : maxFPS)
        renderer?.setFrameRate(fps)

        let external = onExternalPower
        captureFPS = (fps >= 120 && external) ? 120 : min(60, fps)

        let moving = model.isEngaged || previewStart != nil || revealSeed != nil || revealArmed
        let poll: Int
        if !prefs.enabled {
            poll = 10
        } else if moving && external && !lowPower && !hot {
            poll = min(120, maxFPS)
        } else {
            poll = 60
        }
        sensor.setPollRate(poll)
    }

    private var onExternalPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSACPowerValue
    }

    // MARK: Suspension (sleep, clamshell, disabled)

    private func reconcileSuspension() {
        if shouldRun {
            if model.isSuspended {
                if wakeRevealPending { model.willWake() } else { model.resume() }
            }
            if wakeRevealPending {
                wakeRevealPending = false
                armReveal()
            }
        } else {
            // Keep the wake intent only while the built-in display is what is holding us back
            // (clamshell wake, or the panel not yet re-enumerated). Sleep or Disabled cancel it.
            if !prefs.enabled || systemAsleep || screensAsleep { wakeRevealPending = false }
            if !model.isSuspended { model.suspend() }
            hideOverlayNow()
            stopCapture(immediately: true)
        }
        publishLive(force: true)
    }

    private func enabledChanged() {
        reconcileSuspension()
        updatePacing()
        updateActivity()
        if prefs.enabled { promptForPermissionOnce() }
    }

    private func displayConfigurationChanged() {
        guard let screen = builtInScreen() else {
            displayID = nil
            reconcileSuspension()
            return
        }
        let id = screen.displayID
        let geometryChanged = id != displayID || (overlay != nil && overlay?.frame != screen.frame)
        if displayID == nil, prefs.enabled, !systemAsleep, !screensAsleep {
            // The built-in panel came back (lid opened from clamshell, or it re-enumerated after
            // wake): reveal the desktop as it lights up.
            duoLog.info("built-in display active again: reveal pending")
            wakeRevealPending = true
        }
        displayID = id
        if geometryChanged {
            hideOverlayNow()
            stopCapture(immediately: true)
            overlay?.fit(to: screen)
        }
        reconcileSuspension()
        updatePacing()
        if geometryChanged {
            // The teardown above leaves an engaged model (or a live preview) with no overlay and
            // no stream, and nothing else calls `syncOverlay()` until the next phase change. Pick
            // straight back up at the new geometry (after `updatePacing()`, which recomputes
            // `captureFPS` for the new mode); a no-op when nothing is wanted.
            syncOverlay()
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        func onWorkspace(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
        func onDefault(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }

        // The sensor keeps polling through sleep on purpose: its timer cannot fire while the
        // Mac is asleep, and the first tick after the freeze is the earliest wake signal.
        onWorkspace(NSWorkspace.willSleepNotification) { [weak self] in
            guard let self else { return }
            duoLog.info("sleeping: angle=\(self.currentAngle ?? -1, privacy: .public)")
            systemAsleep = true
            reconcileSuspension()
        }
        onWorkspace(NSWorkspace.screensDidSleepNotification) { [weak self] in
            guard let self else { return }
            screensAsleep = true
            reconcileSuspension()
        }
        onWorkspace(NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            systemAsleep = false
            wake()
        }
        onWorkspace(NSWorkspace.screensDidWakeNotification) { [weak self] in
            guard let self else { return }
            screensAsleep = false
            wake()
        }
        onDefault(NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.displayConfigurationChanged()
        }
        onDefault(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.updatePacing() }
        onDefault(.NSProcessInfoPowerStateDidChange) { [weak self] in self?.updatePacing() }

        // The lock screen sits above the overlay; the unlock is the moment the desktop shows.
        let distributed = DistributedNotificationCenter.default()
        func onDistributed(_ name: String, _ handler: @escaping @MainActor () -> Void) {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
        onDistributed("com.apple.screenIsLocked") { [weak self] in self?.screenLocked = true }
        onDistributed("com.apple.screenIsUnlocked") { [weak self] in
            guard let self else { return }
            screenLocked = false
            duoLog.info("screen unlocked")
            if revealArmed { playReveal() }
        }
    }

    private func wake() {
        guard !systemAsleep, !screensAsleep else { return }
        refreshPermission()
        let now = ProcessInfo.processInfo.systemUptime
        if revealArmed || revealSeed != nil || wakeRevealPending || now - lastWakeAt < Self.wakeDebounce {
            // The sensor gap already started this wake; the notification adds nothing.
            reconcileSuspension()
            return
        }
        lastWakeAt = now
        duoLog.info("wake: angle=\(self.currentAngle ?? -1, privacy: .public)")
        wakeRevealPending = true
        reconcileSuspension()
        // The HID service may have been reset; the poller self-heals, but a nudge is cheaper.
        if !sensorAvailable { sensor.restart() }
        updatePacing()
    }

    // MARK: Status

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
        }
    }

    private func publishLive(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPublish >= 0.1 else { return }
        lastPublish = now
        if lidAngle != currentAngle { lidAngle = currentAngle }
        let line = describeState()
        if line != statusLine { statusLine = line }
    }

    private func describeState() -> String {
        let angle = currentAngle.map { String(format: "%.1f°", $0) }
        if !prefs.enabled { return "Disabled" + (angle.map { " · lid \($0)" } ?? "") }
        if systemAsleep || screensAsleep { return "Asleep" }
        if builtInScreen() == nil { return "Built-in display inactive" }
        if !sensorAvailable { return "Lid sensor unavailable" }
        if previewStart != nil { return "Previewing…" }
        if revealArmed { return "Waking · waiting for the desktop" }
        if revealSeed != nil { return "Revealing…" }
        if model.isClosed { return "Lid closed" }
        let a = angle ?? "—"
        let ref = model.reference.map { String(format: "%.0f°", $0) } ?? "—"
        switch model.phase {
        case .engaged: return "Lid \(a) · folding from \(ref)"
        case .clearing: return "Lid \(a) · clearing"
        case .idle:
            if !hasScreenRecording { return "Lid \(a) · needs Screen Recording" }
            return "Lid \(a) · " + (model.isStill ? "resting" : "moving") + " · from \(ref)"
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
