import AppKit

/// Borderless panel that exactly covers the built-in display and hosts the Metal view.
///
/// It sits just above the status-bar layer, never takes focus or mouse events, joins every
/// Space (including full-screen apps), and is hidden from screen sharing and capture.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen, contentView view: NSView) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = 0
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
        fit(to: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-cover `screen` after a resolution or arrangement change.
    func fit(to screen: NSScreen) {
        if frame != screen.frame { setFrame(screen.frame, display: false) }
    }

    /// Put the panel on screen, invisible; alpha follows coverage once a frame has rendered.
    func show() {
        alphaValue = 0
        orderFrontRegardless()
    }

    func hide() {
        alphaValue = 0
        orderOut(nil)
    }
}
