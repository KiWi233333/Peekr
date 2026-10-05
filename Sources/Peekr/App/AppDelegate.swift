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
    private var agentServer: AgentControlServer?
    private var agentTargetSync: AgentTargetSync?
    private var bookmarkSyncTimer: Timer?
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
        let currentSearchEngine: () -> SearchEngine = { [weak self] in
            self?.settings.searchEngine ?? .google
        }
        model = AppModel(store: AppStore(), searchEngine: currentSearchEngine)
        bookmarks = BookmarksModel(store: BookmarkStore())
        icons = IconStore()
        icons.warm(model.apps)
        badges = BadgeStore()

        manager = WebViewManager(
            model: model,
            factory: CefSwiftEngineFactory(
                onOpenNewTab: { [weak self] url, foreground in
                    self?.manager.openInNewTab(urlString: url.absoluteString, foreground: foreground)
                },
                strings: { [weak self] in self?.settings.strings ?? Localized(isChinese: false) },
                searchEngine: currentSearchEngine
            ),
            badges: badges,
            icons: icons,
            searchEngine: currentSearchEngine
        )
        model.onWorkspaceSwitch = { [weak self] oldID, newID in
            self?.manager.prepareForWorkspaceSwitch(from: oldID, to: newID)
        }
        model.onWorkspaceProfileChange = { [weak self] workspaceID, _, _ in
            self?.manager.prepareForProfileChange(workspaceID: workspaceID)
        }
        // Tear down a deleted tab's web engine (stops background media, frees the
        // process) and its badge — the model itself stays web-agnostic.
        model.onRemove = { [weak self] id in self?.manager.discard(id) }
        panel = PanelController(model: model, settings: settings, manager: manager, icons: icons, badges: badges, bookmarks: bookmarks)
        panel.onQuitShortcut = { [weak self] in self?.requestQuit() }
        panel.onVisibilityChange = { [weak self] visible in
            self?.edge.setArmed(!visible)
            self?.manager.setPanelVisible(visible)
        }
        // The panel starts hidden; agent-created pages should still enter the
        // ordinary idle lifecycle schedule before the first manual show.
        manager.setPanelVisible(false)

        // Hover the docked edge/corner to peek the panel out.
        edge = EdgeTrigger(settings: settings)
        edge.onTrigger = { [weak self] in self?.panel.show() }
        edge.start()

        // Opt-in launch hook for automated native UI/design verification. It is
        // inert for normal launches and avoids requiring Accessibility permission
        // merely to press the global shortcut in a test environment.
        if ProcessInfo.processInfo.environment["PEEKR_SHOW_PANEL_ON_LAUNCH"] == "1" {
            panel.show()
        }

        applyHotKey()

        browserImports = BrowserImportWindowController(
            model: model,
            bookmarks: bookmarks,
            settings: settings,
            icons: icons
        )

        prefs = PreferencesWindowController(
            model: model,
            bookmarks: bookmarks,
            settings: settings,
            icons: icons,
            onApply: { [weak self] effect in self?.applyPreference(effect) },
            onImportBrowserData: { [weak self] in self?.browserImports.show() },
            onInstallAgentCLI: { [weak self] in self?.installAgentCLI() }
        )

        statusBar = StatusBarController(
            model: model,
            settings: settings,
            isPanelVisible: { [weak self] in self?.panel.isVisible ?? false },
            onToggle: { [weak self] in self?.panel.toggle() },
            onTogglePin: { [weak self] in self?.model.isPinned.toggle() },
            onImportBrowserData: { [weak self] in self?.browserImports.show() },
            onPreferences: { [weak self] in self?.prefs.show() },
            onQuit: { [weak self] in self?.requestQuit() }
        )

        // Keep the login item in sync with the saved preference.
        LaunchAtLogin.set(settings.launchAtLogin)

        // Agent access mirrors the CEF DevTools port decided at launch: the
        // discovery file exists exactly while the port is listening, and the
        // control server (spaces/ownership) shares its lifetime.
        if settings.agentAccessEnabled, (1...65535).contains(settings.agentDebugPort) {
            let debugPort = settings.agentDebugPort
            let token = UUID().uuidString
            let server = AgentControlServer(model: model, token: token)
            agentServer = server
            // Mirror agent-created Chromium pages into the rail so user and
            // agent see one browser.
            let sync = AgentTargetSync(model: model, port: debugPort)
            server.pages = sync
            sync.prepareNativeTab = { [weak self] id in self?.manager.prepareAgentTab(id) }
            sync.loadNativeTab = { [weak self] id, url in self?.manager.loadAgentTab(id, url: url) }
            sync.activateNativeTab = { [weak self] workspaceID, tabID in
                self?.model.selectWorkspace(workspaceID)
                self?.model.select(tabID)
                self?.manager.activate(tabID)
                self?.panel.show()
            }
            agentTargetSync = sync
            sync.start()
            Task { @MainActor [weak self] in
                do {
                    let controlPort = try await server.start()
                    AgentDiscovery.publish(
                        port: debugPort,
                        controlPort: controlPort,
                        token: token
                    )
                } catch {
                    // CDP-only fallback: discovery still works for page ops.
                    FileHandle.standardError.write(
                        Data("Peekr: agent control server failed to start: \(error)\n".utf8)
                    )
                    AgentDiscovery.publish(port: debugPort)
                    self?.agentServer = nil
                }
            }
        } else {
            agentServer?.stop()
            agentServer = nil
            agentTargetSync?.stop()
            agentTargetSync = nil
            AgentDiscovery.revoke()
        }

        // Refresh imported bookmarks once now, then on the chosen interval.
        if settings.bookmarkSync != .off { bookmarks.syncFromBrowsers() }
        applyBookmarkSync()

        #if DEBUG
        // Deterministic real-CEF smoke hook for local/CI bundles. It is compiled
        // out of release builds and never changes persisted settings or tabs.
        if ProcessInfo.processInfo.environment["PEEKR_SMOKE_SHOW_PANEL"] == "1" {
            if let rawURL = ProcessInfo.processInfo.environment["PEEKR_SMOKE_URL"],
               let firstID = model.apps.first?.id {
                // Smoke navigation must stay in memory; model.update(_:) writes
                // apps.json and would replace the user's real first tab.
                smokeTarget: for workspaceIndex in model.workspaces.indices {
                    guard let tabIndex = model.workspaces[workspaceIndex].tabs
                        .firstIndex(where: { $0.id == firstID })
                    else { continue }
                    model.workspaces[workspaceIndex].tabs[tabIndex].urlString = rawURL
                    break smokeTarget
                }
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
        }
    }

    /// Register the bundled peekr harness on PATH (`~/.local/bin/peekr`) so
    /// agent CLIs reach it without repo checkouts. Requires Node ≥ 22; the
    /// result is surfaced because the target audience may be non-terminal users.
    private func installAgentCLI() {
        let loc = settings.strings
        let binDir = NSHomeDirectory() + "/.local/bin"
        let linkURL = URL(fileURLWithPath: binDir + "/peekr")

        func bundledLauncher() -> URL? {
            for candidate in [Bundle.main.bundleURL, URL(fileURLWithPath: "/Applications/Peekr.app")] {
                let url = candidate
                    .appendingPathComponent("Contents/Resources/peekr-cli/peekr", isDirectory: false)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
            return nil
        }

        guard let launcher = bundledLauncher() else {
            showImportAlert(
                title: loc.cliInstallFailedTitle,
                message: loc.cliInstallMissingBundle
            )
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: linkURL.path) {
                try FileManager.default.removeItem(at: linkURL)
            }
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: launcher)
            showImportAlert(
                title: loc.cliInstallDoneTitle,
                message: loc.cliInstallDoneMessage(linkURL.path)
            )
        } catch {
            showImportAlert(
                title: loc.cliInstallFailedTitle,
                message: error.localizedDescription
            )
        }
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
