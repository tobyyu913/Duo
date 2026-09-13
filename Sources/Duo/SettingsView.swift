import AppKit
import SwiftUI

/// The Settings window contents: effect sliders, the "Reveal by" angle, login item, status.
struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Effect") {
                slider("Perspective", value: $prefs.perspective)
                slider("Softness", value: $prefs.blur)
                slider("Shadow", value: $prefs.shadow)
            }

            Section("Lid") {
                Toggle("Enabled", isOn: $prefs.enabled)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Reveal by")
                        Spacer()
                        Text("\(Int(prefs.clearsAt.rounded()))°")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $prefs.clearsAt, in: Preferences.clearsAtRange, step: 1)
                    HStack {
                        Text(currentAngleText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use current angle") {
                            if let angle = model.lidAngle {
                                prefs.clearsAt = angle.rounded()
                            }
                        }
                        .disabled(model.lidAngle == nil)
                    }
                    Text("Closing the lid from wherever it rests starts the effect. When opening from closed or after sleep there is no resting angle to measure from, so the desktop is fully revealed by this angle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $prefs.launchAtLogin)
                    .disabled(Bundle.main.bundleIdentifier == nil)
                if let error = prefs.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Status") {
                statusRow("Lid", model.statusLine)
                statusRow("Sensor", model.sensorStatus)
                HStack {
                    Text("Screen Recording")
                    Spacer()
                    if model.hasScreenRecording {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Grant…") { model.requestPermissionIfNeeded() }
                    }
                }
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var currentAngleText: String {
        guard let angle = model.lidAngle else { return "Lid angle unavailable" }
        return String(format: "Current lid angle %.1f°", angle)
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Hosts `SettingsView` in a plain titled window that stays out of full-screen Spaces.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let prefs: Preferences
    private var window: NSWindow?

    init(model: AppModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(prefs: prefs, model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Duo Settings"
            window.styleMask = [.titled, .closable]
            window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.refreshPermission()
        prefs.refreshLaunchAtLogin()
        if window?.isVisible != true { model.liveObservers += 1 }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.liveObservers = max(0, model.liveObservers - 1)
        }
    }
}
