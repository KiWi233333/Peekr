import AppKit

/// Owns one `WebEngine` per dock app and keeps them alive across show/hide so
/// sessions, scroll position and playback are never lost. Backend-agnostic: it
/// builds engines through a `WebEngineFactory` and only ever speaks the
/// `WebEngine` protocol, so the backend never reaches the panel or UI layer.
/// Mirrors the active engine's nav state into `state`.
@MainActor
final class WebViewManager {
    let state = BrowserState()
    let downloads = DownloadStore()

    private let model: AppModel
    private var factory: WebEngineFactory
    private let badges: BadgeStore
    private let icons: IconStore
    private let searchEngine: () -> SearchEngine
    private var historyStore: HistoryStore
    private var zoomStore: ZoomStore
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

    init(
        model: AppModel,
        factory: WebEngineFactory,
        badges: BadgeStore,
        icons: IconStore,
        searchEngine: @escaping () -> SearchEngine = { .google },
        historyStore: HistoryStore = HistoryStore(),
        zoomStore: ZoomStore = ZoomStore()
    ) {
        self.model = model
        self.factory = factory
        self.badges = badges
        self.icons = icons
        self.searchEngine = searchEngine
        self.historyStore = historyStore
        self.zoomStore = zoomStore
    }

    var historyEntries: [HistoryEntry] { historyStore.entries }

    // MARK: - Lifecycle

    /// Ensure an engine exists for `id`, make it current and mirror its state.
    func activate(_ id: UUID) {
        guard let app = model.allTabs.first(where: { $0.id == id }) else { return }
        let engine = engine(for: app)
        applyStoredZoom(to: engine, for: engine.navState.url ?? app.url)
        state.currentID = id
        mirror(engine.navState)
    }

    func view(for id: UUID) -> NSView? { engines[id]?.hostView }

    /// Mount background agent pages once so the rail later reuses the exact same CEF view.
    func prepareAgentTab(_ id: UUID) {
        guard let app = model.tab(id) else { return }
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

    func discard(_ id: UUID) {
        let wasCurrent = state.currentID == id
        engines[id]?.close()
        engines[id]?.hostView.removeFromSuperview()
        engines[id] = nil
        agentHosts.removeValue(forKey: id)?.close()
        lastTitles[id] = nil
        lastHosts[id] = nil
        lastHistoryURLs[id] = nil
        downloadEngines = downloadEngines.filter { $0.value != id }
        icons.discardNavigation(for: id)
        badges.clear(id)
        if wasCurrent {
            state.currentID = nil
            if let nextID = model.selectedID, nextID != id { activate(nextID) }
        }
    }

    /// Force-close every cached page before CefSwift begins process-wide
    /// termination. This prevents a page's `beforeunload` handler from keeping
    /// the menu-bar app alive indefinitely after the user already confirmed quit.
    func closeAll() {
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
        state.currentID = nil
    }

    // MARK: - Navigation actions (operate on the active engine)

    func goBack() { current?.goBack() }
    func goForward() { current?.goForward() }
    func reloadOrStop() {
        guard let current else { return }
        if current.navState.isLoading {
            current.stopLoading()
        } else {
            current.reload()
        }
    }
    /// Retry the active tab's failed navigation without changing its URL.
    func retryCurrentPage() { current?.reload() }
    func reloadIgnoringCache() { current?.reload(ignoreCache: true) }

    func zoomIn() { changeZoom { $0.zoomIn() } }
    func zoomOut() { changeZoom { $0.zoomOut() } }
    func zoomReset() {
        guard let current, let origin = zoomOrigin(for: current) else { return }
        current.zoomReset()
        zoomStore.reset(for: origin)
    }

    func toggleMute(_ id: UUID) {
        guard let app = model.tab(id) else { return }
        let muted = !(engines[id]?.isAudioMuted ?? app.isMuted)
        engines[id]?.isAudioMuted = muted
        var updated = app
        updated.isMuted = muted
        model.update(updated)
    }

    func cancelDownload(_ id: UInt32) {
        guard let engineID = downloadEngines[id] else { return }
        engines[engineID]?.cancelDownload(id)
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
        current?.stopFinding()
    }

    /// Live search as the user types: each keystroke is a fresh session that
    /// jumps to the first match, mirroring Chrome's incremental find.
    func updateFindQuery(_ query: String) {
        findBar.query = query
        guard !query.isEmpty else { current?.stopFinding(); return }
        current?.find(query, forward: true, matchCase: false)
    }

    func findNext() { find(forward: true) }
    func findPrevious() { find(forward: false) }

    private func find(forward: Bool) {
        guard !findBar.query.isEmpty else { return }
        current?.find(findBar.query, forward: forward, matchCase: false)
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
        guard !text.isEmpty,
              let url = Self.url(fromOmnibox: text, searchEngine: searchEngine())
        else { return }
        if let current {
            current.load(url)
        } else {
            let app = model.addApp(title: url.displayHost ?? text, urlString: url.absoluteString)
            activate(app.id)
        }
    }

    /// Omnibox ⌘Return: resolve the input exactly like `loadAddress`, then
    /// open it in a background tab instead of navigating the current one.
    func loadAddressInBackgroundTab(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = Self.url(fromOmnibox: text, searchEngine: searchEngine())
        else { return }
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

    private func engine(for app: WebApp) -> WebEngine {
        if let existing = engines[app.id] { return existing }
        let engine = factory.makeEngine(for: app, profile: model.profile(forTab: app.id))
        let id = app.id
        lastTitles[id] = app.title
        lastHosts[id] = IconStore.normalizedHost(app.host)
        icons.followNavigation(app, pageURL: app.url)
        // Every engine reports its nav state — foreground or not — so background
        // tabs keep their unread badge, rail title and icon current. Only the
        // foreground page drives the shared `BrowserState` the nav bar binds to.
        engine.onNavStateChange = { [weak self] nav in
            guard let self else { return }
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
                let pageURL = nav.url
                Task { [weak self] in
                    guard let self, let engine = self.engines[id] else { return }
                    let links = await engine.iconLinkURLs()
                    self.icons.syncFavicon(app, pageURL: pageURL, domLinks: links)
                }
            }
            self.recordHistory(id: id, navigation: nav)
            if id == self.state.currentID { self.mirror(nav) }
        }
        engine.onDownloadChange = { [weak self] download in
            guard let self else { return }
            self.downloads.update(download)
            if download.state == .downloading {
                self.downloadEngines[download.id] = id
            } else {
                self.downloadEngines.removeValue(forKey: download.id)
            }
        }
        engines[id] = engine
        return engine
    }

    private func recordHistory(id: UUID, navigation: NavState) {
        guard !navigation.isLoading, let url = navigation.url else { return }
        let urlString = url.absoluteString
        guard lastHistoryURLs[id] != urlString else { return }
        lastHistoryURLs[id] = urlString

        let fallback = model.tab(id)?.displayName ?? url.displayHost ?? urlString
        historyStore.record(url: url, title: navigation.title.isEmpty ? fallback : navigation.title)
    }

    private func changeZoom(_ action: (WebEngine) -> Void) {
        guard let current else { return }
        action(current)
        guard let origin = zoomOrigin(for: current) else { return }
        zoomStore.set(current.zoomLevel, for: origin)
    }

    private func applyStoredZoom(to engine: WebEngine, for url: URL?) {
        guard let url, let origin = Self.zoomOrigin(for: url) else { return }
        let level = zoomStore.level(for: origin)
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
        if state.canGoBack != nav.canGoBack { state.canGoBack = nav.canGoBack }
        if state.canGoForward != nav.canGoForward { state.canGoForward = nav.canGoForward }
        if state.isLoading != nav.isLoading { state.isLoading = nav.isLoading }
        if state.progress != nav.progress { state.progress = nav.progress }
        let urlString = nav.url?.absoluteString ?? ""
        if state.urlString != urlString { state.urlString = urlString }
        if state.title != nav.title { state.title = nav.title }
        if state.loadError != nav.loadError { state.loadError = nav.loadError }
        if state.rendererFailure != nav.rendererFailure { state.rendererFailure = nav.rendererFailure }
    }
}
