import AppKit

/// Menu-bar only app: no Dock icon, no main window. Everything hangs off `AppModel`.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences?
    private var model: AppModel?
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let prefs = Preferences()
        let model = AppModel(prefs: prefs)
        self.prefs = prefs
        self.model = model
        statusMenu = StatusMenu(model: model, prefs: prefs)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    /// `open duo://preview` plays the preview, `duo://reveal` plays the opening reveal as if the
    /// Mac had just woken, `duo://settings` opens Settings, `duo://status` writes a status line
    /// to the log — handy from a terminal or a Shortcut.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "duo" {
            switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "preview": model?.startPreview()
            case "reveal": model?.startReveal()
            case "settings": statusMenu?.showSettings()
            case "status": model?.logStatus()
            default: break
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// The uniforms struct is copied into the GPU byte for byte; catch a layout drift before the
// first frame rather than as a subtly wrong picture. Debug builds only.
DuoUniforms.assertLayout()

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
