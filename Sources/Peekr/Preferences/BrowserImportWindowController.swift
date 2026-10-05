import AppKit
import SwiftUI

/// Presents the unified browser-data import from surfaces that do not own a
/// SwiftUI sheet, such as the menu-bar menu and the Browser preferences tab.
@MainActor
final class BrowserImportWindowController {
    private let model: AppModel
    private let bookmarks: BookmarksModel
    private let settings: Settings
    private let icons: IconStore
    private var window: NSWindow?

    init(model: AppModel, bookmarks: BookmarksModel, settings: Settings, icons: IconStore) {
        self.model = model
        self.bookmarks = bookmarks
        self.settings = settings
        self.icons = icons
    }

    func show() {
        let view = BrowserImportSheet(
            model: model,
            bookmarks: bookmarks,
            settings: settings,
            icons: icons
        ) { [weak self] in
            self?.window?.close()
        }

        if let window {
            window.title = settings.strings.importTitle
            window.contentView = NSHostingView(rootView: view)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = settings.strings.importTitle
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: view)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
