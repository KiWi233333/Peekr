import AppKit
import SwiftUI

/// Lazily creates and shows the Preferences window (a normal titled window
/// hosting the SwiftUI `PreferencesView`).
@MainActor
final class PreferencesWindowController {
    private let model: AppModel
    private let bookmarks: BookmarksModel
    private let settings: Settings
    private let icons: IconStore
    private let onApply: (PreferenceEffect) -> Void
    private let onImportBrowserData: () -> Void
    private let onInstallAgentCLI: () -> Void
    private var window: NSWindow?

    init(
        model: AppModel,
        bookmarks: BookmarksModel,
        settings: Settings,
        icons: IconStore,
        onApply: @escaping (PreferenceEffect) -> Void,
        onImportBrowserData: @escaping () -> Void,
        onInstallAgentCLI: @escaping () -> Void
    ) {
        self.model = model
        self.bookmarks = bookmarks
        self.settings = settings
        self.icons = icons
        self.onApply = onApply
        self.onImportBrowserData = onImportBrowserData
        self.onInstallAgentCLI = onInstallAgentCLI
    }

    func show() {
        if window == nil {
            let view = PreferencesView(
                model: model,
                bookmarks: bookmarks,
                settings: settings,
                icons: icons,
                onApply: onApply,
                onImportBrowserData: onImportBrowserData,
                onInstallAgentCLI: onInstallAgentCLI
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
