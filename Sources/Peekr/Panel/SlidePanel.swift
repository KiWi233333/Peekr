import AppKit

/// A borderless, non-activating floating panel that hosts the web content.
/// Non-activating means peeking it out won't steal focus from your current app,
/// yet it can still become key so you can type into web apps.
final class SlidePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Keep the active web app's timers / requestAnimationFrame running while
        // the panel is occluded or slid off-screen — WebKit otherwise throttles
        // offscreen views to ~1 Hz (browser-correct, but wrong for a live
        // slide-over). See the native-feel WebView survival guide, A.1.
        setValue(false, forKey: "windowOcclusionDetectionEnabled")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
