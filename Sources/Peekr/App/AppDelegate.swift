import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: Settings!
    private var model: AppModel!
    private var bookmarks: BookmarksModel!
    private var icons: IconStore!
    private var manager: WebViewManager!
    private var panel: PanelController!
    private var edge: EdgeTrigger!
    private var statusBar: StatusBarController!
    private var prefs: PreferencesWindowController!
    private var bookmarkSyncTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings(store: SettingsStore())
        // The main menu carries the standard editing key equivalents (⌘X/C/V/A/Z)
        // so text fields in the panel and Preferences are actually editable.
        installMainMenu(strings: settings.strings)
        model = AppModel(store: AppStore())
        bookmarks = BookmarksModel(store: BookmarkStore())
        icons = IconStore()
        icons.warm(model.apps)

        manager = WebViewManager(model: model, factory: WebKitEngineFactory())
        panel = PanelController(model: model, settings: settings, manager: manager, icons: icons, bookmarks: bookmarks)
        panel.onVisibilityChange = { [weak self] visible in self?.edge.setArmed(!visible) }

        // Hover the docked edge/corner to peek the panel out.
        edge = EdgeTrigger(settings: settings)
        edge.onTrigger = { [weak self] in self?.panel.show() }
        edge.start()

        applyHotKey()

        prefs = PreferencesWindowController(
            model: model, settings: settings, icons: icons,
            onApply: { [weak self] in self?.applyPreferences() }
        )

        statusBar = StatusBarController(
            model: model,
            settings: settings,
            onToggle: { [weak self] in self?.panel.toggle() },
            onTogglePin: { [weak self] in self?.model.isPinned.toggle() },
            onPreferences: { [weak self] in self?.prefs.show() }
        )

        // Keep the login item in sync with the saved preference.
        LaunchAtLogin.set(settings.launchAtLogin)

        // Refresh imported bookmarks once now, then on the chosen interval.
        if settings.bookmarkSync != .off { bookmarks.syncFromBrowsers() }
        applyBookmarkSync()
    }

    /// (Re)arm the periodic bookmark re-import based on the current setting.
    private func applyBookmarkSync() {
        bookmarkSyncTimer?.invalidate()
        bookmarkSyncTimer = nil
        guard let interval = settings.bookmarkSync.seconds else { return }
        bookmarkSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.bookmarks.syncFromBrowsers() }
        }
    }

    private func applyHotKey() {
        GlobalHotKeyCenter.shared.setPrimary(settings.hotKey) { [weak self] in
            self?.panel.toggle()
        }
    }

    private func applyPreferences() {
        applyHotKey()
        panel.applyLayout()
        applyBookmarkSync()
    }
}
