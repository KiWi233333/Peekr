import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: Settings!
    private var model: AppModel!
    private var bookmarks: BookmarksModel!
    private var icons: IconStore!
    private var badges: BadgeStore!
    private var manager: WebViewManager!
    private var panel: PanelController!
    private var edge: EdgeTrigger!
    private var statusBar: StatusBarController!
    private var prefs: PreferencesWindowController!
    private var bookmarkSyncTimer: Timer?
    private var activeWebEngine: WebEngineKind!
    private var isQuitPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings(store: SettingsStore())
        // The main menu carries the standard editing key equivalents (⌘X/C/V/A/Z)
        // so text fields in the panel and Preferences are actually editable.
        installMainMenu(
            strings: settings.strings,
            quitTarget: self,
            quitAction: #selector(requestQuit)
        )
        model = AppModel(store: AppStore())
        bookmarks = BookmarksModel(store: BookmarkStore())
        icons = IconStore()
        icons.warm(model.apps)
        badges = BadgeStore()

        activeWebEngine = settings.webEngine
        manager = WebViewManager(
            model: model,
            factory: activeWebEngine.makeFactory(),
            badges: badges,
            icons: icons
        )
        // Tear down a deleted tab's web engine (stops background media, frees the
        // process) and its badge — the model itself stays web-agnostic.
        model.onRemove = { [weak self] id in self?.manager.discard(id) }
        panel = PanelController(model: model, settings: settings, manager: manager, icons: icons, badges: badges, bookmarks: bookmarks)
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
            onPreferences: { [weak self] in self?.prefs.show() },
            onQuit: { [weak self] in self?.requestQuit() }
        )

        // Keep the login item in sync with the saved preference.
        LaunchAtLogin.set(settings.launchAtLogin)

        // Refresh imported bookmarks once now, then on the chosen interval.
        if settings.bookmarkSync != .off { bookmarks.syncFromBrowsers() }
        applyBookmarkSync()

        #if DEBUG
        // Deterministic real-CEF smoke hook for local/CI bundles. It is compiled
        // out of release builds and never changes persisted settings or tabs.
        if ProcessInfo.processInfo.environment["PEEKR_SMOKE_SHOW_PANEL"] == "1" {
            if let rawURL = ProcessInfo.processInfo.environment["PEEKR_SMOKE_URL"],
               var app = model.apps.first {
                app.urlString = rawURL
                model.update(app)
            }
            panel.show()
        }
        if let rawDelay = ProcessInfo.processInfo.environment["PEEKR_SMOKE_QUIT_AFTER"],
           let delay = Double(rawDelay) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.performConfirmedQuit()
            }
        }
        #endif
    }

    /// Confirm user-driven quit before calling `terminate(_:)`. CefSwift then
    /// closes every CEF browser and shuts the runtime down before AppKit exits.
    /// Intercepting here (rather than `applicationShouldTerminate`) is important:
    /// CefSwift's NSApplication subclass performs CEF teardown before AppKit asks
    /// its delegate, which would leave a canceled quit with a dead runtime.
    @objc private func requestQuit() {
        let loc = settings.strings
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc.quitConfirmTitle
        alert.informativeText = loc.quitConfirmMessage
        alert.addButton(withTitle: loc.quit)    // .alertFirstButtonReturn
        alert.addButton(withTitle: loc.cancel)
        // An .accessory agent isn't frontmost; without activating, the alert
        // opens behind the active app where the user can't see it.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            performConfirmedQuit()
        }
    }

    private func performConfirmedQuit() {
        guard !isQuitPending else { return }
        isQuitPending = true
        manager.closeAll()
        // CefBrowser's before-close callback releases the browser before its
        // renderer hosts finish detaching from the BrowserContext. Calling
        // cef_shutdown synchronously from that callback trips Chromium's
        // observer/reference assertions. Let CefSwift's external message pump
        // drain the close notifications before its terminate handler shuts
        // down the process-wide runtime.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.terminate(nil)
        }
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
        if activeWebEngine != settings.webEngine {
            activeWebEngine = settings.webEngine
            manager.replaceFactory(activeWebEngine.makeFactory())
        }
    }
}
