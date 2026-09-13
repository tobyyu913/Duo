import AppKit
import CoreMedia
import ScreenCaptureKit

enum DuoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// The newest captured frame, shared between the capture queue and the render loop.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var revision: UInt64 = 0

    /// Stores a frame. Returns `true` when this is the first frame since the store was cleared.
    func put(_ frame: CVPixelBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = buffer == nil
        buffer = frame
        revision &+= 1
        return first
    }

    func latest() -> (frame: CVPixelBuffer, revision: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, revision)
    }

    var hasFrame: Bool {
        lock.lock(); defer { lock.unlock() }
        return buffer != nil
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer = nil
        revision &+= 1
    }
}

/// ScreenCaptureKit stream of the built-in display at native pixel size.
///
/// Our own application is excluded from the content filter so the overlay is never captured
/// recursively. Frames land in `frames`; the render loop picks up the newest one.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = FrameStore()

    /// Main thread: the first complete frame of a stream has arrived.
    var onFirstFrame: (@MainActor () -> Void)?
    /// Main thread: the stream ended on its own (error, display gone, permission revoked).
    var onStopped: (@MainActor (Error?) -> Void)?

    private let queue = DispatchQueue(label: "com.toby.duo.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var generation = 0
    private var starting = false

    var isRunning: Bool { stream != nil || starting }

    // MARK: Permission

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once per process; later calls return the current state silently.
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Lifecycle (main thread)

    @MainActor func start(displayID: CGDirectDisplayID, pixelSize: CGSize, fps: Int) async throws {
        guard !isRunning else { return }
        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            guard token == generation else { return }
            throw error
        }
        guard token == generation else { return }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DuoError.message("The built-in display is not available for capture.")
        }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Leave colorSpaceName unset: frames stay in the display's own colour space, so the
        // untagged overlay presents them back pixel-exact on any profile.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        frames.clear()
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            if token == generation { self.stream = nil }
            throw error
        }
        if token != generation {
            // stop() ran while we were starting.
            try? await stream.stopCapture()
        }
    }

    @MainActor func stop() {
        generation += 1
        starting = false
        let old = stream
        stream = nil
        frames.clear()
        if let old { Task { try? await old.stopCapture() } }
    }

    // MARK: SCStreamOutput (capture queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let raw = attachments?.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if frames.put(pixelBuffer) {
            Task { @MainActor [weak self] in
                guard let self, self.stream === stream else { return }
                self.onFirstFrame?()
            }
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.frames.clear()
            self.onStopped?(error)
        }
    }
}
