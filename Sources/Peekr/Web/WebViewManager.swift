import AppKit

/// Owns one `WebEngine` per dock app and keeps them alive across show/hide so
/// sessions, scroll position and playback are never lost. Backend-agnostic: it
/// builds engines through a `WebEngineFactory` and only ever speaks the
/// `WebEngine` protocol, so the backend never reaches the panel or UI layer.
/// Mirrors the active engine's nav state into `state`.
@MainActor
final class WebViewManager {
    let state = BrowserState()
    let downloads: DownloadStore
    let browsingData: BrowsingDataCleaner

    private let model: AppModel
    private var factory: WebEngineFactory
    private let badges: BadgeStore
    private let icons: IconStore
    private let searchEngine: () -> SearchEngine
    private var historyStore: HistoryStore
    private var engines: [UUID: WebEngine] = [:]
    private var agentHosts: [UUID: NSWindow] = [:]
    private var downloadEngines: [UInt32: UUID] = [:]
    /// Last title seen per engine, so the badge/title pipeline only runs on a real
    /// title change and not on every `estimatedProgress` KVO tick during a load.
    private var lastTitles: [UUID: String] = [:]
    /// Last normalized host seen per engine. Crossing hosts immediately replaces
    /// stale title/icon presentation while the destination document is loading.
    private var lastHosts: [UUID: String] = [:]
    private var lastHistoryURLs: [UUID: String] = [:]

    private struct PageRuntime {
        var lifecycle: WebPageLifecycle = .closed
        var lastActiveAt: Date
        var generation: UInt64 = 0
        var recoveryAttempts = 0
        var activity = WebActivitySnapshot()
        var isAutomationControlled = false
    }

    private enum SweepReason {
        case visibility
        case memoryPressure
        case manual
    }

    private var runtimes: [UUID: PageRuntime] = [:]
    private var engineIdentities: [UUID: ObjectIdentifier] = [:]
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var hibernationTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var panelIsVisible = true
    private let hibernationPolicy: HibernationPolicy
    private let now: () -> Date

    init(
        model: AppModel,
        factory: WebEngineFactory,
        badges: BadgeStore,
        icons: IconStore,
        searchEngine: @escaping () -> SearchEngine = { .google },
        historyStore: HistoryStore = HistoryStore(),
        zoomStore: ZoomStore = ZoomStore(),
        downloadStore: DownloadStore? = nil,
        hibernationPolicy: HibernationPolicy = HibernationPolicy(idleThreshold: 1_800),
        now: @escaping () -> Date = Date.init
    ) {
        self.model = model
        self.factory = factory
        self.badges = badges
        self.icons = icons
        let resolvedDownloads = downloadStore ?? DownloadStore(
            fileURL: AppPaths.supportDirectory.appendingPathComponent("downloads.json")
        )
        downloads = resolvedDownloads
        self.searchEngine = searchEngine
        self.historyStore = historyStore
        browsingData = BrowsingDataCleaner(
            history: historyStore,
            downloads: resolvedDownloads,
            permissions: SitePermissionStore.shared,
            zoom: zoomStore
        )
        self.hibernationPolicy = hibernationPolicy
        self.now = now
        installMemoryPressureSource()
    }

    var historyEntries: [HistoryEntry] { historyStore.entries }
    var history: HistoryStore { historyStore }

    // MARK: - Lifecycle

    /// Ensure an engine exists for `id`, make it current and mirror its state.
    func activate(_ id: UUID) {
        guard let app = model.allTabs.first(where: { $0.id == id }) else { return }
        state.blockedPopupCount = 0
        if let page = app.url.flatMap(InternalPage.from) {
            state.currentID = id
            state.internalPage = page
            state.urlString = ""
            state.title = app.displayName
            state.canGoBack = false
            state.canGoForward = false
            state.isLoading = false
            state.progress = 1
            state.loadError = nil
            state.rendererFailure = nil
            return
        }
        state.internalPage = nil
        if runtimes[id]?.lifecycle == .crashed {
            state.currentID = id
            state.pageLifecycle = .crashed
            return
        }
        var runtime = runtime(for: id)
        let shouldRestore = runtime.lifecycle == .asleep || runtime.lifecycle == .restoring
        runtime.lastActiveAt = now()
        if shouldRestore {
            runtime.lifecycle = .restoring
        }
        runtimes[id] = runtime
        let engine = engine(for: app)
        let audio = engine.activity.audio
        if var updatedRuntime = runtimes[id] {
            updatedRuntime.activity = WebActivitySnapshot(audio: audio)
            runtimes[id] = updatedRuntime
        }
        model.setAudible(id, audio == .audible)
        applyStoredZoom(to: engine, for: engine.navState.url ?? app.url)
        state.currentID = id
        mirror(engine.navState)
        state.zoomLevel = engine.zoomLevel
        if shouldRestore {
            restore(id, expectedGeneration: runtime.generation)
        } else {
            setLifecycle(.live, for: id)
        }
    }

    func view(for id: UUID) -> NSView? { engines[id]?.hostView }

    /// Show one of Peekr's native pages above the current tab. The web engine
    /// stays mounted so closing the page returns to the same document.
    func openInternalPage(_ page: InternalPage) {
        state.internalPage = page
        state.loadError = nil
        state.rendererFailure = nil
    }

    /// Leave the native page and re-mirror the active engine's navigation state.
    func closeInternalPage() {
        guard state.internalPage != nil else { return }
        state.internalPage = nil
        if let current {
            mirror(current.navState)
        } else {
            state.urlString = ""
            state.title = ""
            state.isLoading = false
            state.progress = 1
            state.loadError = nil
            state.rendererFailure = nil
        }
    }

    func toggleTabSearch() {
        state.tabSearchOpen.toggle()
    }

    func clearBlockedPopups() {
        state.blockedPopupCount = 0
    }

    /// Close engines owned by a Workspace before the model changes the active
    /// binding. The next activation creates a fresh engine lazily under the
    /// destination Workspace's Profile.
    func prepareForWorkspaceSwitch(from oldWorkspaceID: UUID, to newWorkspaceID: UUID) {
        let ids = model.workspaces.first(where: { $0.id == oldWorkspaceID })?.tabs.map(\.id) ?? []
        for id in ids { closeEngine(id, clearPresentation: false, lifecycle: .asleep) }
        if ids.contains(state.currentID ?? UUID()) { state.currentID = nil }
    }

    func prepareForProfileChange(workspaceID: UUID) {
        let ids = model.workspaces.first(where: { $0.id == workspaceID })?.tabs.map(\.id) ?? []
        for id in ids { closeEngine(id, clearPresentation: false, lifecycle: .asleep) }
        if ids.contains(state.currentID ?? UUID()) { state.currentID = nil }
    }

    /// Mount background agent pages once so the rail later reuses the exact same CEF view.
    func prepareAgentTab(_ id: UUID) {
        guard let app = model.tab(id) else { return }
        var runtime = runtime(for: id)
        runtime.isAutomationControlled = true
        runtimes[id] = runtime
        let engine = engine(for: app)
        guard engine.hostView.window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        engine.hostView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = engine.hostView
        agentHosts[id] = window
    }

    func loadAgentTab(_ id: UUID, url: URL) { engines[id]?.load(url) }

    func reload(_ id: UUID) { engines[id]?.reload() }

    /// Manual sleep is intentionally separate from the automatic policy and
    /// may be used even for an audible or currently selected page.
    @discardableResult
    func sleep(_ id: UUID) -> Bool {
        guard engines[id] != nil else { return false }
        closeEngine(id, clearPresentation: false, lifecycle: .asleep)
        if state.currentID == id {
            state.currentID = nil
            state.pageLifecycle = .asleep
        }
        return true
    }

    func wake(_ id: UUID) {
        activate(id)
    }

    func isAsleep(_ id: UUID) -> Bool {
        runtimes[id]?.lifecycle == .asleep
    }

    /// Deterministic lifecycle entry point used by tests and by the visibility
    /// timer. Memory-pressure sweeps may run while the panel is visible, but
    /// the ordinary idle sweep only runs while it is hidden.
    @discardableResult
    func sweep(now sweepDate: Date = Date()) -> [UUID] {
        sweep(reason: .manual, at: sweepDate)
    }

    @discardableResult
    private func sweep(reason: SweepReason, at sweepDate: Date) -> [UUID] {
        guard reason == .memoryPressure || !panelIsVisible else { return [] }
        let candidates = model.allTabs.compactMap { app -> HibernationCandidate? in
            guard engines[app.id] != nil else { return nil }
            let runtime = runtime(for: app.id, at: sweepDate)
            let reported = runtime.activity.audio
            // The console callback is authoritative once it has reported;
            // otherwise a backend's synchronous snapshot is the only signal.
            let activity = reported == .unknown
                ? (engines[app.id]?.activity.audio ?? .unknown)
                : reported
            return HibernationCandidate(
                id: app.id,
                lastActiveAt: runtime.lastActiveAt,
                isActive: state.currentID == app.id,
                keepAwake: app.keepAwake,
                isAsleep: runtime.lifecycle == .asleep,
                isAutomationControlled: runtime.isAutomationControlled,
                audioActivity: activity
            )
        }
        let ids = hibernationPolicy.tabsToHibernate(candidates, now: sweepDate)
        for id in ids { _ = sleep(id) }
        return ids
    }

    func setPanelVisible(_ visible: Bool) {
        panelIsVisible = visible
        hibernationTimer?.invalidate()
        hibernationTimer = nil
        guard !visible, hibernationPolicy.idleThreshold > 0 else { return }
        let interval = min(60, max(1, hibernationPolicy.idleThreshold / 4))
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.sweep(reason: .visibility, at: self.now())
            }
        }
    }

    func discard(_ id: UUID) {
        let wasCurrent = state.currentID == id
        closeEngine(id, clearPresentation: true)
        if wasCurrent {
            state.currentID = nil
            if let nextID = model.selectedID, nextID != id { activate(nextID) }
        }
    }

    /// Force-close every cached page before CefSwift begins process-wide
    /// termination. This prevents a page's `beforeunload` handler from keeping
    /// the menu-bar app alive indefinitely after the user already confirmed quit.
    func closeAll() {
        hibernationTimer?.invalidate()
        hibernationTimer = nil
        recoveryTasks.values.forEach { $0.cancel() }
        recoveryTasks.removeAll()
        for engine in engines.values {
            engine.close()
            engine.hostView.removeFromSuperview()
        }
        engines.removeAll()
        for window in agentHosts.values { window.close() }
        agentHosts.removeAll()
        lastTitles.removeAll()
        lastHosts.removeAll()
        lastHistoryURLs.removeAll()
        downloadEngines.removeAll()
        engineIdentities.removeAll()
        runtimes.removeAll()
        model.clearAudibleTabs()
        state.currentID = nil
        state.pageLifecycle = .closed
    }

    // MARK: - Navigation actions (operate on the active engine)

    func goBack() {
        if state.internalPage != nil {
            closeInternalPage()
            return
        }
        current?.goBack()
    }

    func goForward() {
        guard state.internalPage == nil else { return }
        current?.goForward()
    }

    func reloadOrStop() {
        guard state.internalPage == nil, let current else { return }
        if current.navState.isLoading {
            current.stopLoading()
        } else {
            current.reload()
        }
    }
    /// Retry the active tab's failed navigation without changing its URL.
    func retryCurrentPage() {
        guard state.internalPage == nil, let id = state.currentID else { return }
        if runtimes[id]?.lifecycle == .crashed || current?.navState.rendererFailure != nil {
            recover(id, resetBudget: true)
        } else {
            current?.reload()
        }
    }
    func reloadIgnoringCache() {
        guard state.internalPage == nil else { return }
        current?.reload(ignoreCache: true)
    }

    /// The cleaner owns the single zoom-store copy; sharing it means a clear is
    /// immediately visible to live zoom lookups instead of surviving in a stale
    /// value copy until relaunch.
    var zoom: ZoomStore { browsingData.zoom }
    var currentZoomLevel: Double { current?.zoomLevel ?? state.zoomLevel }

    func setDefaultZoom(_ level: Double) {
        browsingData.zoom.setDefault(level)
    }

    func zoomIn() { changeZoom { $0.zoomIn() } }
    func zoomOut() { changeZoom { $0.zoomOut() } }
    func zoomReset() {
        guard state.internalPage == nil, let current, let origin = zoomOrigin(for: current) else { return }
        current.zoomReset()
        browsingData.zoom.reset(for: origin)
        state.zoomLevel = current.zoomLevel
        state.zoomToastToken += 1
    }

    func toggleDevTools() {
        guard state.internalPage == nil else { return }
        current?.toggleDevTools()
    }

    func viewSource() {
        guard state.internalPage == nil else { return }
        current?.viewSource()
    }

    func toggleMute(_ id: UUID) {
        guard let app = model.tab(id) else { return }
        let muted = !(engines[id]?.isAudioMuted ?? app.isMuted)
        engines[id]?.isAudioMuted = muted
        var updated = app
        updated.isMuted = muted
        model.update(updated)
        model.setAudible(id, engines[id]?.activity.audio == .audible)
    }

    func cancelDownload(_ id: UInt32) {
        guard let engineID = downloadEngines[id] else { return }
        engines[engineID]?.cancelDownload(id)
    }

    func pauseDownload(_ id: UInt32) {
        guard let engineID = downloadEngines[id] else { return }
        engines[engineID]?.pauseDownload(id)
        downloads.setPaused(id, true)
    }

    func resumeDownload(_ id: UInt32) {
        guard let engineID = downloadEngines[id] else { return }
        engines[engineID]?.resumeDownload(id)
        downloads.setPaused(id, false)
    }

    /// A terminal download no longer has a CEF callback. Retry by requesting
    /// the source URL again, which starts a fresh download item.
    func retryDownload(_ record: DownloadRecord) {
        downloads.remove(id: record.id)
        guard let url = record.url else { return }
        loadAddress(url.absoluteString)
    }

    // MARK: - Find in page (⌘F)

    let findBar = FindBarState()

    func openFindBar() {
        findBar.isVisible = true
        findBar.focusToken += 1
    }

    func closeFindBar() {
        guard findBar.isVisible else { return }
        findBar.isVisible = false
        findBar.matches = 0
        findBar.activeMatch = 0
        current?.stopFinding()
    }

    /// Live search as the user types: each keystroke is a fresh session that
    /// jumps to the first match, mirroring Chrome's incremental find.
    func updateFindQuery(_ query: String) {
        findBar.query = query
        findBar.matches = 0
        findBar.activeMatch = 0
        guard !query.isEmpty else { current?.stopFinding(); return }
        current?.find(query, forward: true, matchCase: findBar.matchCase)
    }

    func findNext() { find(forward: true) }
    func findPrevious() { find(forward: false) }

    func toggleFindCase() {
        findBar.matchCase.toggle()
        guard !findBar.query.isEmpty else { return }
        findBar.matches = 0
        findBar.activeMatch = 0
        current?.find(findBar.query, forward: true, matchCase: findBar.matchCase)
    }

    private func find(forward: Bool) {
        guard !findBar.query.isEmpty else { return }
        current?.find(findBar.query, forward: forward, matchCase: findBar.matchCase)
    }

    /// A page asked for a new tab (⌘-click, middle-click, target=_blank,
    /// window.open, context menu). Foreground requests select and activate the
    /// tab; background ones only record it — the engine (and the page load)
    /// starts lazily on first activation, Peekr's standing model for
    /// non-selected tabs.
    func openInNewTab(urlString: String, foreground: Bool) {
        let title = URL(string: urlString)?.displayHost ?? urlString
        let app = model.addApp(title: title, urlString: urlString, select: foreground)
        if foreground { activate(app.id) }
    }

    /// Omnibox: treat input as a URL when it looks like one, else web-search it.
    /// With an active tab, navigate it; in an empty workspace (no tab selected)
    /// open the address in a fresh tab so the bar always works.
    func loadAddress(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = URL(string: text), let page = InternalPage.from(url) {
            openInternalPage(page)
            return
        }
        guard let url = Self.url(fromOmnibox: text, searchEngine: searchEngine()) else { return }
        if let id = state.currentID, model.selectedID != id {
            model.select(id)
        }
        closeInternalPage()
        state.urlString = url.absoluteString
        state.title = url.displayHost ?? text
        state.isLoading = true
        state.progress = 0
        state.loadError = nil
        state.rendererFailure = nil
        if let current {
            current.load(url)
        } else if let id = state.currentID, let app = model.tab(id) {
            let engine = engine(for: app)
            state.currentID = id
            engine.load(url)
        } else {
            let app = model.addApp(title: url.displayHost ?? text, urlString: url.absoluteString)
            activate(app.id)
        }
    }

    /// Omnibox ⌘Return: resolve the input exactly like `loadAddress`, then
    /// open it in a background tab instead of navigating the current one.
    func loadAddressInBackgroundTab(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = URL(string: text), InternalPage.isInternal(url) {
            openInNewTab(urlString: url.absoluteString, foreground: false)
            return
        }
        guard let url = Self.url(fromOmnibox: text, searchEngine: searchEngine()) else { return }
        openInNewTab(urlString: url.absoluteString, foreground: false)
    }

    static func url(fromOmnibox text: String, searchEngine: SearchEngine = .google) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text)
        }
        // Any other explicit scheme (file://, custom protocols) is an address.
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            return URL(string: text)
        }
        // localhost / IP literals (optionally with :port and /path) navigate
        // directly instead of being searched, like Chrome.
        let hostPart = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
        let isLocalhost = hostPart == "localhost" || hostPart.hasPrefix("localhost:")
        let isIPv4 = hostPart.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?$"#, options: .regularExpression) != nil
        let isIPv6 = hostPart.hasPrefix("[") && hostPart.contains("]")
        if isLocalhost || isIPv4 || isIPv6 {
            return URL(string: "http://\(text)")
        }
        let looksLikeDomain = !text.contains(" ") && text.contains(".")
        if looksLikeDomain, let url = URL(string: "https://\(text)") {
            return url
        }
        return searchEngine.searchURL(for: text)
    }

    // MARK: - Private

    private var current: WebEngine? { state.currentID.flatMap { engines[$0] } }

    private func runtime(for id: UUID, at date: Date? = nil) -> PageRuntime {
        if let existing = runtimes[id] { return existing }
        return PageRuntime(lastActiveAt: date ?? now())
    }

    private func setLifecycle(_ lifecycle: WebPageLifecycle, for id: UUID) {
        guard var runtime = runtimes[id] else { return }
        runtime.lifecycle = lifecycle
        runtimes[id] = runtime
        if state.currentID == id { state.pageLifecycle = lifecycle }
    }

    private func isCurrentEngine(
        _ id: UUID,
        generation: UInt64,
        identity: ObjectIdentifier
    ) -> Bool {
        runtimes[id]?.generation == generation
            && engineIdentities[id] == identity
    }

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.sweep(reason: .memoryPressure, at: self.now())
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    @discardableResult
    private func closeEngine(
        _ id: UUID,
        clearPresentation: Bool,
        lifecycle: WebPageLifecycle = .closed
    ) -> UInt64 {
        var runtime = runtime(for: id)
        runtime.generation &+= 1
        runtime.lifecycle = lifecycle
        runtimes[id] = runtime
        recoveryTasks[id]?.cancel()
        recoveryTasks[id] = nil
        engines[id]?.close()
        engines[id]?.hostView.removeFromSuperview()
        engines[id] = nil
        engineIdentities[id] = nil
        agentHosts.removeValue(forKey: id)?.close()
        downloadEngines = downloadEngines.filter { $0.value != id }
        model.setAudible(id, false)
        if clearPresentation {
            lastTitles[id] = nil
            lastHosts[id] = nil
            lastHistoryURLs[id] = nil
            icons.discardNavigation(for: id)
            badges.clear(id)
        }
        if state.currentID == id { state.pageLifecycle = lifecycle }
        return runtime.generation
    }

    private func engine(for app: WebApp) -> WebEngine {
        if let existing = engines[app.id] { return existing }
        var runtime = runtime(for: app.id)
        if runtime.lifecycle != .restoring { runtime.lifecycle = .live }
        runtime.activity = WebActivitySnapshot()
        runtimes[app.id] = runtime
        let generation = runtime.generation
        let engine = factory.makeEngine(for: app, profile: model.profile(forTab: app.id))
        let id = app.id
        let identity = ObjectIdentifier(engine)
        engineIdentities[id] = identity
        lastTitles[id] = app.title
        lastHosts[id] = IconStore.normalizedHost(app.host)
        icons.followNavigation(app, pageURL: app.url)
        // Every engine reports its nav state — foreground or not — so background
        // tabs keep their unread badge, rail title and icon current. Only the
        // foreground page drives the shared `BrowserState` the nav bar binds to.
        engine.onNavStateChange = { [weak self] nav in
            guard let self else { return }
            guard self.isCurrentEngine(id, generation: generation, identity: identity) else { return }
            if let failure = nav.rendererFailure {
                self.handleRendererFailure(
                    id: id,
                    failure: failure,
                    nav: nav,
                    generation: generation,
                    identity: identity
                )
                return
            }
            let host = IconStore.normalizedHost(nav.url?.displayHost)
            let hostChanged = host != nil && self.lastHosts[id] != host
            let titleChanged = self.lastTitles[id] != nav.title
            // Title-derived work (badge regex + rail title) only on a real title
            // change — `estimatedProgress` ticks repeat the same title otherwise.
            if titleChanged {
                self.lastTitles[id] = nav.title
                self.badges.update(id, fromTitle: nav.title)
                self.model.applyLiveTitle(id, to: nav.title)
            }
            // URL events commonly arrive before the destination title/favicon.
            // Switch presentation immediately; retain an already-arrived new
            // title, otherwise use the destination host until document.title lands.
            if let host, hostChanged,
               let app = self.model.allTabs.first(where: { $0.id == id }) {
                self.lastHosts[id] = host
                self.icons.followNavigation(app, pageURL: nav.url)
                if !titleChanged || nav.title.isEmpty {
                    self.badges.update(id, fromTitle: "")
                    self.model.applyLiveTitle(id, to: host)
                }
            }
            if hostChanged {
                self.applyStoredZoom(to: engine, for: nav.url)
            }
            // Once the page settles, read its favicon links from the live DOM and
            // refresh the icon. Gated to a settled page so a redirect chain doesn't
            // fetch each hop's icon; `syncFavicon` then no-ops unless the host
            // actually changed.
            if !nav.isLoading, let app = self.model.allTabs.first(where: { $0.id == id }) {
                self.model.applyLiveNavigation(id, url: nav.url, title: nav.title)
                let pageURL = nav.url
                Task { [weak self] in
                    guard let self, self.isCurrentEngine(id, generation: generation, identity: identity) else { return }
                    let links = await engine.iconLinkURLs()
                    guard self.isCurrentEngine(id, generation: generation, identity: identity) else { return }
                    self.icons.syncFavicon(app, pageURL: pageURL, domLinks: links)
                }
            }
            if !nav.isLoading {
                self.runtimeDidSettle(id)
            }
            self.recordHistory(id: id, navigation: nav)
            if id == self.state.currentID { self.mirror(nav) }
        }
        engine.onDownloadChange = { [weak self] download in
            guard let self else { return }
            guard self.isCurrentEngine(id, generation: generation, identity: identity) else { return }
            self.downloads.update(download, persist: !self.model.isPrivateTab(id))
            if download.state == .downloading {
                self.downloadEngines[download.id] = id
            } else {
                self.downloadEngines.removeValue(forKey: download.id)
            }
        }
        engine.onFindResult = { [weak self] result in
            guard let self, self.state.currentID == id else { return }
            self.findBar.matches = result.matches
            // CEF may report ordinal 0 for the first result of a session even
            // when matches exist; present it as the first match.
            self.findBar.activeMatch = result.matches > 0
                ? max(1, result.activeMatchOrdinal)
                : 0
        }
        engine.onAudioActivityChange = { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            guard self.isCurrentEngine(id, generation: generation, identity: identity) else { return }
            let audio = engine.activity.audio
            var runtime = self.runtime(for: id)
            runtime.activity = WebActivitySnapshot(audio: audio)
            self.runtimes[id] = runtime
            self.model.setAudible(id, audio == .audible)
        }
        engine.onBlockedPopup = { [weak self] _ in
            guard let self, self.state.currentID == id else { return }
            self.state.blockedPopupCount += 1
        }
        engines[id] = engine
        return engine
    }

    private func recordHistory(id: UUID, navigation: NavState) {
        guard !model.isPrivateTab(id) else { return }
        guard !navigation.isLoading, let url = navigation.url else { return }
        let urlString = url.absoluteString
        guard lastHistoryURLs[id] != urlString else { return }
        lastHistoryURLs[id] = urlString

        let fallback = model.tab(id)?.displayName ?? url.displayHost ?? urlString
        historyStore.record(url: url, title: navigation.title.isEmpty ? fallback : navigation.title)
    }

    private func runtimeDidSettle(_ id: UUID) {
        guard var runtime = runtimes[id] else { return }
        runtime.lifecycle = .live
        runtimes[id] = runtime
        if state.currentID == id { state.pageLifecycle = .live }
    }

    private func handleRendererFailure(
        id: UUID,
        failure: WebRendererFailure,
        nav: NavState,
        generation: UInt64,
        identity: ObjectIdentifier
    ) {
        guard isCurrentEngine(id, generation: generation, identity: identity),
              var runtime = runtimes[id] else { return }

        if runtime.recoveryAttempts >= 1 {
            runtime.lifecycle = .crashed
            runtimes[id] = runtime
            if state.currentID == id {
                state.pageLifecycle = .crashed
                mirror(nav)
            }
            return
        }

        runtime.recoveryAttempts += 1
        runtimes[id] = runtime
        let expectedGeneration = closeEngine(
            id,
            clearPresentation: false,
            lifecycle: .restoring
        )
        if state.currentID == id {
            state.pageLifecycle = .restoring
            state.rendererFailure = nil
        }
        scheduleRecovery(id, expectedGeneration: expectedGeneration)
        _ = failure // retained in the NavState delivered to the explicit retry UI
    }

    private func scheduleRecovery(_ id: UUID, expectedGeneration: UInt64) {
        recoveryTasks[id]?.cancel()
        recoveryTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self,
                  self.runtimes[id]?.generation == expectedGeneration,
                  self.runtimes[id]?.lifecycle == .restoring,
                  self.model.tab(id) != nil else { return }
            self.recoveryTasks[id] = nil
            self.restore(id, expectedGeneration: expectedGeneration)
        }
    }

    private func restore(_ id: UUID, expectedGeneration: UInt64) {
        guard runtimes[id]?.generation == expectedGeneration,
              runtimes[id]?.lifecycle == .restoring,
              let app = model.tab(id) else { return }
        let engine = engine(for: app)
        // CefSwift stores this as pendingURL until its host view is mounted;
        // fake engines observe the same recovery contract directly.
        if let url = app.url { engine.load(url) }
        if state.currentID == id {
            applyStoredZoom(to: engine, for: app.url)
            mirror(engine.navState)
            state.pageLifecycle = .live
        }
        setLifecycle(.live, for: id)
    }

    private func recover(_ id: UUID, resetBudget: Bool) {
        guard model.tab(id) != nil else { return }
        var runtime = runtime(for: id)
        if resetBudget { runtime.recoveryAttempts = 0 }
        runtimes[id] = runtime
        let generation = closeEngine(id, clearPresentation: false, lifecycle: .restoring)
        restore(id, expectedGeneration: generation)
    }

    private func changeZoom(_ action: (WebEngine) -> Void) {
        guard let current else { return }
        action(current)
        state.zoomLevel = current.zoomLevel
        state.zoomToastToken += 1
        guard let origin = zoomOrigin(for: current) else { return }
        browsingData.zoom.set(current.zoomLevel, for: origin)
    }

    private func applyStoredZoom(to engine: WebEngine, for url: URL?) {
        guard let url, let origin = Self.zoomOrigin(for: url) else { return }
        let level = browsingData.zoom.level(for: origin)
        if engine.zoomLevel != level {
            // The protocol's command methods are intentionally step-based, but
            // CEF exposes the absolute level so a host change can be restored
            // in one operation when the backend supports it.
            if let cef = engine as? CefSwiftEngine {
                cef.setZoomLevel(level)
            } else {
                engine.zoomReset()
                if level > 0 {
                    for _ in 0..<Int(level) { engine.zoomIn() }
                } else {
                    for _ in 0..<Int(-level) { engine.zoomOut() }
                }
            }
        }
    }

    private func zoomOrigin(for engine: WebEngine) -> String? {
        Self.zoomOrigin(for: engine.navState.url)
    }

    private static func zoomOrigin(for url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme?.lowercased() ?? "https")://\(host)\(port)"
    }

    /// Copy only the fields that actually changed. `@Observable` setters don't
    /// diff, so an unconditional write marks every field mutated — and a loading
    /// page floods us with `estimatedProgress` ticks. Guarding each write keeps a
    /// progress tick from invalidating the back/forward buttons and omnibox too.
    private func mirror(_ nav: NavState) {
        guard state.internalPage == nil else { return }
        if state.canGoBack != nav.canGoBack { state.canGoBack = nav.canGoBack }
        if state.canGoForward != nav.canGoForward { state.canGoForward = nav.canGoForward }
        if state.isLoading != nav.isLoading { state.isLoading = nav.isLoading }
        if state.progress != nav.progress { state.progress = nav.progress }
        let urlString = nav.url?.absoluteString ?? ""
        if state.urlString != urlString { state.urlString = urlString }
        if state.title != nav.title { state.title = nav.title }
        if state.loadError != nav.loadError { state.loadError = nav.loadError }
        if state.rendererFailure != nav.rendererFailure { state.rendererFailure = nav.rendererFailure }
        if let zoom = current?.zoomLevel, state.zoomLevel != zoom { state.zoomLevel = zoom }
    }
}
