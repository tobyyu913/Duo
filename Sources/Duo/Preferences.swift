import Combine
import Foundation
import ServiceManagement

/// User settings, persisted in `UserDefaults`. Launch at Login is read from (and written to)
/// the system via `SMAppService`, so it always reflects what macOS actually holds.
@MainActor final class Preferences: ObservableObject {
    private enum Key {
        static let perspective = "perspective"
        static let blur = "blur"
        static let shadow = "shadow"
        static let clearsAt = "clearsAt"
        static let enabled = "enabled"
    }

    static let clearsAtRange: ClosedRange<Double> = 60...140

    @Published var perspective: Double { didSet { save(perspective, Key.perspective) } }
    @Published var blur: Double { didSet { save(blur, Key.blur) } }
    @Published var shadow: Double { didSet { save(shadow, Key.shadow) } }
    @Published var clearsAt: Double {
        didSet {
            let clamped = min(Self.clearsAtRange.upperBound, max(Self.clearsAtRange.lowerBound, clearsAt))
            if clamped != clearsAt { clearsAt = clamped; return }
            save(clearsAt, Key.clearsAt)
        }
    }
    @Published var enabled: Bool { didSet { save(enabled, Key.enabled) } }

    /// Mirrors `SMAppService.mainApp.status`; set it to register or unregister.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !syncingLaunchAtLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            // macOS may accept register() (or throw kSMErrorLaunchDeniedByUser) yet leave the item
            // waiting on the user in System Settings. Take them there instead of silently snapping back.
            if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            refreshLaunchAtLogin()
        }
    }
    @Published private(set) var launchAtLoginError: String?
    private static let approvalNote = "Approve Duo in System Settings › General › Login Items & Extensions."

    private let defaults: UserDefaults
    private var syncingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        perspective = defaults.object(forKey: Key.perspective) as? Double ?? 0.7
        blur = defaults.object(forKey: Key.blur) as? Double ?? 0.65
        shadow = defaults.object(forKey: Key.shadow) as? Double ?? 0.65
        clearsAt = defaults.object(forKey: Key.clearsAt) as? Double ?? 110
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Re-read the login item state; the user can also change it in System Settings.
    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        if status == .requiresApproval {
            launchAtLoginError = Self.approvalNote
        } else if launchAtLoginError == Self.approvalNote {
            launchAtLoginError = nil
        }
        let actual = status == .enabled
        guard actual != launchAtLogin else { return }
        syncingLaunchAtLogin = true
        launchAtLogin = actual
        syncingLaunchAtLogin = false
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
