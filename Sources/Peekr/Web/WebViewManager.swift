import AppKit

/// Owns one `WebEngine` per dock app and keeps them alive across show/hide so
/// sessions, scroll position and playback are never lost. Backend-agnostic: it
/// builds engines through a `WebEngineFactory` and only ever speaks the
/// `WebEngine` protocol, so the backend never reaches the panel or UI layer.
/// Mirrors the active engine's nav state into `state`.
@MainActor
final class WebViewManager {
    let state = BrowserState()

    private let model: AppModel
    private var factory: WebEngineFactory
    private let badges: BadgeStore
    private let icons: IconStore
    private let searchEngine: () -> SearchEngine
    private var engines: [UUID: WebEngine] = [:]
    /// Last title seen per engine, so the badge/title pipeline only runs on a real
    /// title change and not on every `estimatedProgress` KVO tick during a load.
    private var lastTitles: [UUID: String] = [:]
    /// Last normalized host seen per engine. Crossing hosts immediately replaces
    /// stale title/icon presentation while the destination document is loading.
    private var lastHosts: [UUID: String] = [:]

    init(
        model: AppModel,
        factory: WebEngineFactory,
        badges: BadgeStore,
        icons: IconStore,
        searchEngine: @escaping () -> SearchEngine = { .google }
    ) {
        self.model = model
        self.factory = factory
        self.badges = badges
        self.icons = icons
        self.searchEngine = searchEngine
    }

    // MARK: - Lifecycle

    /// Ensure an engine exists for `id`, make it current and mirror its state.
    func activate(_ id: UUID) {
        guard let app = model.allTabs.first(where: { $0.id == id }) else { return }
        let engine = engine(for: app)
        state.currentID = id
        mirror(engine.navState)
    }

    func view(for id: UUID) -> NSView? { engines[id]?.hostView }

    func reload(_ id: UUID) { engines[id]?.reload() }

    func discard(_ id: UUID) {
        let wasCurrent = state.currentID == id
        engines[id]?.close()
        engines[id]?.hostView.removeFromSuperview()
        engines[id] = nil
        lastTitles[id] = nil
        lastHosts[id] = nil
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
        lastTitles.removeAll()
        lastHosts.removeAll()
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

    static func url(fromOmnibox text: String, searchEngine: SearchEngine = .google) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text)
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
        let engine = factory.makeEngine(for: app)
        let id = app.id
        // The agent target sync binds CDP targets to rail tabs; announce the
        // one moment a target is guaranteed to appear for a known tab.
        NotificationCenter.default.post(
            name: .peekrTabEngineActivated,
            object: nil,
            userInfo: ["tabID": id]
        )
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
            if id == self.state.currentID { self.mirror(nav) }
        }
        engines[id] = engine
        return engine
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
    }
}
