import AppKit
import SwiftUI

/// Lazily creates and shows the Preferences window (a normal titled window
/// hosting the SwiftUI `PreferencesView`).
@MainActor
final class PreferencesWindowController {
    private let model: AppModel
    private let settings: Settings
    private let icons: IconStore
    private let onApply: (PreferenceEffect) -> Void
    private let onImportCookies: () -> Void
    private let onImportBookmarks: () -> Void
    private var window: NSWindow?

    init(
        model: AppModel,
        settings: Settings,
        icons: IconStore,
        onApply: @escaping (PreferenceEffect) -> Void,
        onImportCookies: @escaping () -> Void,
        onImportBookmarks: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.icons = icons
        self.onApply = onApply
        self.onImportCookies = onImportCookies
        self.onImportBookmarks = onImportBookmarks
    }

    func show() {
        if window == nil {
            let view = PreferencesView(
                model: model,
                settings: settings,
                icons: icons,
                onApply: onApply,
                onImportCookies: onImportCookies,
                onImportBookmarks: onImportBookmarks
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = settings.strings.preferencesWindowTitle
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: view)
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshTitle() {
        window?.title = settings.strings.preferencesWindowTitle
    }
}
