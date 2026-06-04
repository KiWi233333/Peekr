import AppKit

// Peekr is a menu-bar "agent" app: no Dock icon, no main window.
// LSUIElement in Info.plist handles the bundled case; setActivationPolicy
// covers `swift run` during development.
// Top-level code runs on the main thread at process start; assume the main
// actor so we can touch @MainActor-isolated app state.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
