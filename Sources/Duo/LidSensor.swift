import Foundation
import IOKit.hid

/// Reads the hinge angle from the MacBook's built-in lid sensor.
///
/// The sensor is an Apple HID device (vendor 0x05AC, usage page 0x20, usage 0x8A,
/// product "las"). Its report layout was identified by Sam Henri Gold's LidAngleSensor:
///   - feature report 7: `[0x07, b0, b1, b2, b3]`, little-endian hundredths of a degree
///   - feature report 1: `[0x01, lo, hi]`, whole degrees (fallback)
/// 0° is closed and a normally open lid reads about 125°. Opening the device needs no
/// permission or entitlement. An external display can expose the same usage, so only
/// devices flagged Built-In are considered.
///
/// All I/O happens on a private queue driven by a `DispatchSourceTimer`; readings are
/// delivered on the main thread. After 15 consecutive failed reads the sensor reports
/// `nil` once, closes the device and retries opening it about once a second.
final class LidSensor {
    enum Report: CFIndex {
        case hundredths = 7
        case wholeDegrees = 1

        var label: String {
            switch self {
            case .hundredths: return "report 7 (0.01°)"
            case .wholeDegrees: return "report 1 (1°)"
            }
        }
    }

    /// Delivered on the main thread for every poll; `nil` once the sensor is unavailable.
    var onReading: (@MainActor (Double?) -> Void)?
    /// Delivered on the main thread when the device is opened or lost.
    var onStatus: (@MainActor (String) -> Void)?
    /// Delivered on the main thread when the poll timer skipped more than a second: the process
    /// was frozen, i.e. the Mac was asleep and is waking now. Fires before the first reading.
    var onGap: (@MainActor (TimeInterval) -> Void)?

    /// A timer silence longer than this cannot be scheduling jitter; it is sleep.
    private static let gapThreshold: TimeInterval = 1.0

    private static let failureLimit = 15

    private let queue = DispatchQueue(label: "com.toby.duo.sensor", qos: .userInteractive)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var report: Report?
    private var timer: DispatchSourceTimer?
    private var buffer = [UInt8](repeating: 0, count: 16)
    private var failures = 0
    private var ticksSinceOpenAttempt = 0
    private var pollHz = 60
    private var running = false
    private var lastTickAt: TimeInterval?

    // MARK: Control (callable from any thread)

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            openDevice()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(pollHz), leeway: .milliseconds(2))
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
            lastTickAt = nil
            closeDevice()
        }
    }

    /// Close and re-open the device; used after wake, when the HID service may have been reset.
    func restart() {
        stop()
        start()
    }

    func setPollRate(_ hz: Int) {
        let hz = max(1, min(240, hz))
        queue.async { [self] in
            guard pollHz != hz else { return }
            pollHz = hz
            timer?.schedule(deadline: .now(), repeating: 1.0 / Double(hz), leeway: .milliseconds(2))
        }
    }

    // MARK: Polling (sensor queue)

    private func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTickAt, now - last > Self.gapThreshold {
            // Back from sleep. The HID service is often reset across it, so re-open at once
            // instead of burning through the failure limit and the one-second retry.
            lastTickAt = now
            let gap = now - last
            openDevice()
            DispatchQueue.main.async { [self] in MainActor.assumeIsolated { onGap?(gap) } }
        }
        lastTickAt = now
        guard device != nil else {
            ticksSinceOpenAttempt += 1
            if ticksSinceOpenAttempt >= pollHz {
                ticksSinceOpenAttempt = 0
                openDevice()
            }
            return
        }
        if let angle = readAngle() {
            failures = 0
            deliver(angle)
        } else {
            failures += 1
            if failures >= Self.failureLimit {
                failures = 0
                ticksSinceOpenAttempt = 0
                closeDevice()
                deliver(nil)
                status("Lid sensor stopped responding; retrying")
            }
        }
    }

    private func openDevice() {
        closeDevice()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            deliver(nil)
            status("Lid sensor unavailable (HID manager)")
            return
        }
        self.manager = manager

        let candidates = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter { candidate in
            (IOHIDDeviceGetProperty(candidate, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue == true
        }
        for candidate in candidates {
            guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            // Decide the report format once; report 7 gives 0.01° steps, report 1 whole degrees.
            for format in [Report.hundredths, .wholeDegrees] where read(format, from: candidate) != nil {
                device = candidate
                report = format
                failures = 0
                status("Lid sensor: \(format.label)")
                return
            }
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        deliver(nil)
        status(candidates.isEmpty ? "No built-in lid sensor found" : "Lid sensor does not answer")
    }

    private func closeDevice() {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
        report = nil
    }

    private func readAngle() -> Double? {
        guard let device, let report else { return nil }
        return read(report, from: device)
    }

    private func read(_ report: Report, from device: IOHIDDevice) -> Double? {
        var length = CFIndex(buffer.count)
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, report.rawValue, base, &length)
        }
        guard status == kIOReturnSuccess, length > 0, buffer[0] == UInt8(report.rawValue) else { return nil }
        let degrees: Double
        switch report {
        case .hundredths:
            guard length >= 5 else { return nil }
            let raw = UInt32(buffer[1]) | UInt32(buffer[2]) << 8 | UInt32(buffer[3]) << 16 | UInt32(buffer[4]) << 24
            degrees = Double(raw) / 100
        case .wholeDegrees:
            guard length >= 3 else { return nil }
            degrees = Double(UInt16(buffer[1]) | UInt16(buffer[2]) << 8)
        }
        return (0...360).contains(degrees) ? degrees : nil
    }

    // MARK: Delivery

    private func deliver(_ angle: Double?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onReading?(angle) }
        }
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onStatus?(text) }
        }
    }
}
