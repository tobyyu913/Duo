import AppKit
import Combine

/// The menu-bar item: a laptop glyph whose menu shows the live lid state and the controls.
@MainActor final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let prefs: Preferences
    private let settings: SettingsWindowController
    private let item: NSStatusItem
    private let menu = NSMenu()

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    private let sensorItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let previewItem = NSMenuItem(title: "Preview Effect", action: #selector(preview), keyEquivalent: "p")
    private let permissionItem = NSMenuItem(title: "Screen Recording", action: #selector(grantPermission), keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var refreshTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
        settings = SettingsWindowController(model: model, prefs: prefs)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let symbol = NSImage(systemSymbolName: "macbook", accessibilityDescription: "Duo")
            ?? NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Duo")
        symbol?.isTemplate = true
        item.button?.image = symbol
        item.button?.toolTip = "Duo"

        for control in [enabledItem, previewItem, permissionItem, launchItem] { control.target = self }
        stateItem.isEnabled = false
        sensorItem.isEnabled = false
        errorItem.isEnabled = false

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quitItem = NSMenuItem(title: "Quit Duo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.autoenablesItems = false
        menu.delegate = self
        menu.items = [
            enabledItem,
            .separator(),
            stateItem,
            sensorItem,
            errorItem,
            .separator(),
            previewItem,
            permissionItem,
            .separator(),
            settingsItem,
            launchItem,
            .separator(),
            quitItem,
        ]
        item.menu = menu

        // `@Published` emits from `willSet`; defer so `refreshStatic()` reads the stored values.
        prefs.$enabled.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatic() }.store(in: &subscriptions)
        prefs.$launchAtLogin.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatic() }.store(in: &subscriptions)
        refreshStatic()
        refreshLive()
    }

    // MARK: NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            model.refreshPermission()
            prefs.refreshLaunchAtLogin()
            model.liveObservers += 1
            refreshStatic()
            refreshLive()
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLive() }
            }
            if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .eventTracking) }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            refreshTimer?.invalidate()
            refreshTimer = nil
            model.liveObservers = max(0, model.liveObservers - 1)
        }
    }

    // MARK: Refresh

    private func refreshStatic() {
        enabledItem.state = prefs.enabled ? .on : .off
        launchItem.state = prefs.launchAtLogin ? .on : .off
        launchItem.isEnabled = Bundle.main.bundleIdentifier != nil
    }

    private func refreshLive() {
        stateItem.title = model.statusLine
        sensorItem.title = model.sensorStatus
        if model.hasScreenRecording {
            permissionItem.title = "Screen Recording: allowed"
            permissionItem.isEnabled = false
        } else {
            permissionItem.title = "Grant Screen Recording…"
            permissionItem.isEnabled = true
        }
        previewItem.isEnabled = prefs.enabled && !model.isPreviewing && model.builtInDisplayActive
        if let error = model.lastError {
            errorItem.title = error
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        prefs.enabled.toggle()
    }

    @objc private func preview() {
        model.startPreview()
    }

    @objc private func grantPermission() {
        model.requestPermissionIfNeeded()
    }

    @objc private func openSettings() {
        showSettings()
    }

    func showSettings() {
        settings.show()
    }

    @objc private func toggleLaunchAtLogin() {
        prefs.launchAtLogin.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
