import Foundation

/// Turns raw lid angles into a `FoldState` target and an "engaged" flag.
///
/// The model tracks a *reference* (resting) angle. Closing more than a deadband below it
/// engages the effect; returning to within a smaller band of it — or above it — clears the
/// effect. The two bands differ so the sensor's ~0.2° resting jitter can never flicker the
/// overlay. The reference re-anchors wherever the lid has rested still for a while (so any
/// closing motion from rest is a fold, however wide the lid was), and is frozen while a
/// clear animation is playing. The user's "Reveal by" angle (`clearsAt`) is only used when
/// there is no resting angle to measure from: opening after sleep or from fully closed, the
/// desktop is revealed as the lid rises toward it.
@MainActor final class LidModel {
    enum Phase: Equatable {
        /// Nothing shown; the reference may re-anchor freely.
        case idle
        /// The effect follows the lid.
        case engaged
        /// The lid came back; the renderer is animating the clear.
        case clearing
    }

    static let closedAngle = 5.0
    static let engageDeadband = 1.0
    static let clearBand = 0.5
    static let stillTolerance = 0.6
    static let stillDuration: TimeInterval = 1.5

    /// The user's "Reveal by" setting: the reference used when opening from closed or sleep.
    var clearsAt: Double = 110 {
        didSet {
            clearsAt = min(140, max(60, clearsAt))
            guard clearsAt != oldValue else { return }
            // Only a reference that came from this setting (no resting angle known) follows it.
            if reference == oldValue, !isStill { reference = clearsAt }
            recompute()
        }
    }

    private(set) var angle: Double?
    private(set) var reference: Double?
    private(set) var phase: Phase = .idle
    private(set) var target: FoldState = .clear
    private(set) var isStill = false
    private(set) var isSuspended = false

    /// Fired on the main thread whenever `phase` or `target` changes.
    var onChange: ((LidModel) -> Void)?

    private var stillAnchor: Double?
    private var stillSince: TimeInterval = 0
    private var pendingWake = false
    /// The reading in hand when the model was suspended (sleep, clamshell). The sensor keeps
    /// polling through a suspension, so `angle` alone would already be the post-wake value.
    private var angleAtSuspend: Double?
    private var angleBeforeSleep: Double?

    var isEngaged: Bool { phase == .engaged }
    var wantsOverlay: Bool { phase != .idle }
    var isClosed: Bool { (angle ?? 180) < Self.closedAngle }

    // MARK: Input

    func observe(angle reading: Double?, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        angle = reading
        guard !isSuspended else { return }

        guard let a = reading else {
            // Sensor gone: nothing to follow. Drop the reference so a recovered sensor starts clean.
            reference = nil
            stillAnchor = nil
            isStill = false
            settle(phase: .idle)
            return
        }

        if a < Self.closedAngle {
            // Fully shut: the OS owns this moment. Hide instantly and measure the re-opening
            // from "Reveal by" so a re-open without sleep still reveals the desktop on the way up.
            stillAnchor = nil
            isStill = false
            reference = clearsAt
            settle(phase: .idle)
            return
        }

        if pendingWake {
            pendingWake = false
            // The sensor is stopped while asleep, so we cannot watch the lid open. Treat this wake
            // as an opening only if the lid was shut when we last looked, or now sits clearly
            // somewhere else (above OR below — a lid closed after the screen slept comes back up
            // from below). A lid that never moved (key/trackpad wake at the desk) just re-anchors
            // where it rests.
            let moved = angleBeforeSleep.map { $0 < Self.closedAngle || abs(a - $0) > 2 * Self.stillTolerance } ?? true
            angleBeforeSleep = nil
            stillAnchor = a
            stillSince = now
            isStill = false
            if moved {
                // Opening after sleep: measure from "Reveal by" and engage straight away so the
                // desktop is revealed as the lid opens.
                reference = clearsAt
                phase = a < clearsAt - Self.clearBand ? .engaged : .idle
            } else {
                reference = a
                phase = .idle
            }
            recompute()
            return
        }

        trackStillness(a, at: now)

        guard let ref = reference else {
            reference = a
            recompute()
            return
        }

        switch phase {
        case .idle, .clearing:
            if a < ref - Self.engageDeadband { phase = .engaged }
        case .engaged:
            if a >= ref - Self.clearBand { phase = .clearing }
        }
        recompute()
    }

    /// The renderer finished animating the clear; the overlay is gone.
    func didFinishClear() {
        guard phase == .clearing else { return }
        phase = .idle
        if isStill, let stillAnchor { reference = stillAnchor }
        recompute()
    }

    /// Sleep, clamshell, or the effect being disabled: drop everything and hide instantly.
    func suspend() {
        if !isSuspended { angleAtSuspend = angle }
        isSuspended = true
        pendingWake = false
        angleBeforeSleep = nil
        reference = nil
        stillAnchor = nil
        isStill = false
        settle(phase: .idle)
    }

    func resume() {
        isSuspended = false
        angleAtSuspend = nil
    }

    /// The Mac is waking: the next reading decides whether the lid is opening from closed
    /// (reveal from "Reveal by") or never moved (plain resume).
    func willWake() {
        isSuspended = false
        pendingWake = true
        angleBeforeSleep = angleAtSuspend ?? angle
        angleAtSuspend = nil
        reference = clearsAt
        stillAnchor = nil
        isStill = false
    }

    // MARK: Internals

    private func trackStillness(_ a: Double, at now: TimeInterval) {
        if let anchor = stillAnchor, abs(a - anchor) < Self.stillTolerance {
            guard !isStill, now - stillSince >= Self.stillDuration else { return }
            isStill = true
            // A lid that has come to rest anywhere becomes the new baseline — unless a clear
            // animation is still playing, in which case `didFinishClear` re-anchors.
            if phase != .clearing { reference = anchor }
        } else {
            stillAnchor = a
            stillSince = now
            isStill = false
        }
    }

    private func settle(phase newPhase: Phase) {
        phase = newPhase
        recompute()
    }

    private func recompute() {
        let newTarget: FoldState
        if phase == .engaged, let a = angle, let ref = reference {
            newTarget = FoldState.at(angle: a, reference: ref)
        } else {
            newTarget = .clear
        }
        let changed = newTarget != target || phase != lastNotifiedPhase
        target = newTarget
        lastNotifiedPhase = phase
        if changed { onChange?(self) }
    }

    private var lastNotifiedPhase: Phase = .idle
}
