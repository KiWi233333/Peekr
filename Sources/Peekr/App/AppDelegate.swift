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
    private var browserImports: BrowserImportWindowController!
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

        browserImports = BrowserImportWindowController(
            model: model,
            settings: settings,
            icons: icons
        )

        prefs = PreferencesWindowController(
            model: model,
            settings: settings,
            icons: icons,
            onApply: { [weak self] effect in self?.applyPreference(effect) },
            onImportCookies: { [weak self] in self?.browserImports.showCookies() },
            onImportBookmarks: { [weak self] in self?.importChromeBookmarks() }
        )

        statusBar = StatusBarController(
            model: model,
            settings: settings,
            isPanelVisible: { [weak self] in self?.panel.isVisible ?? false },
            onToggle: { [weak self] in self?.panel.toggle() },
            onTogglePin: { [weak self] in self?.model.isPinned.toggle() },
            onImportCookies: { [weak self] in self?.browserImports.showCookies() },
            onImportBookmarks: { [weak self] in self?.importChromeBookmarks() },
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

    private func applyPreference(_ effect: PreferenceEffect) {
        switch effect {
        case .layout:
            panel.applyLayout()
        case .hotKey:
            applyHotKey()
        case .launchAtLogin:
            LaunchAtLogin.set(settings.launchAtLogin)
        case .language:
            installMainMenu(
                strings: settings.strings,
                quitTarget: self,
                quitAction: #selector(requestQuit)
            )
            prefs.refreshTitle()
        case .bookmarkSync:
            applyBookmarkSync()
        case .webEngine:
            guard activeWebEngine != settings.webEngine else { return }
            activeWebEngine = settings.webEngine
            manager.replaceFactory(activeWebEngine.makeFactory())
        }
    }

    private func importChromeBookmarks() {
        let loc = settings.strings
        let profiles: [(profile: ChromeProfile, fileURL: URL)] =
            ChromeCookieImporter.discoverProfiles().compactMap { profile in
                let fileURL = profile.directoryURL.appendingPathComponent("Bookmarks")
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return nil
                }
                return (profile: profile, fileURL: fileURL)
            }
        guard !profiles.isEmpty else {
            showImportAlert(
                title: loc.chromeBookmarksUnavailableTitle,
                message: loc.chromeBookmarksUnavailableMessage
            )
            return
        }

        let profilePicker = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 300, height: 26),
            pullsDown: false
        )
        for candidate in profiles {
            profilePicker.addItem(
                withTitle: "\(candidate.profile.name) — \(candidate.profile.id)"
            )
        }

        let confirmation = NSAlert()
        confirmation.alertStyle = .informational
        confirmation.messageText = loc.chromeBookmarksConfirmTitle
        confirmation.informativeText = loc.chromeBookmarksConfirmMessage(
            profiles.count == 1 ? profiles[0].profile.name : loc.chromeProfile
        )
        if profiles.count > 1 {
            confirmation.accessoryView = profilePicker
        }
        confirmation.addButton(withTitle: loc.importChromeBookmarks)
        confirmation.addButton(withTitle: loc.cancel)
        NSApp.activate(ignoringOtherApps: true)
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let selectedIndex = profiles.count > 1
            ? max(0, profilePicker.indexOfSelectedItem)
            : 0
        let selected = profiles[selectedIndex]
        let source = BookmarkImporter.Source(
            name: "Chrome",
            fileURL: selected.fileURL,
            isSafari: false
        )
        let imported = BookmarkImporter.importBookmarks(from: source)
        guard !imported.isEmpty else {
            showImportAlert(
                title: loc.chromeBookmarksEmptyTitle,
                message: loc.chromeBookmarksEmptyMessage
            )
            return
        }

        let folderName = selected.profile.id == "Default"
            ? "Chrome"
            : "Chrome — \(selected.profile.name)"
        bookmarks.importOrRefreshNodes(imported, as: folderName)
        showImportAlert(
            title: loc.chromeBookmarksImportedTitle,
            message: loc.chromeBookmarksImportedMessage
        )
    }

    private func showImportAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: settings.strings.done)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
