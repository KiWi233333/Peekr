import AppKit

/// Owns one `WebEngine` per dock app and keeps them alive across show/hide so
/// sessions, scroll position and playback are never lost. Backend-agnostic: it
/// builds engines through a `WebEngineFactory` and only ever speaks the
/// `WebEngine` protocol, so swapping in a Chromium/CEF backend never reaches the
/// panel or UI layer. Mirrors the active engine's nav state into `state`.
@MainActor
final class WebViewManager {
    let state = BrowserState()

    private let model: AppModel
    private let factory: WebEngineFactory
    private let badges: BadgeStore
    private let icons: IconStore
    private var engines: [UUID: WebEngine] = [:]
    /// Last title seen per engine, so the badge/title pipeline only runs on a real
    /// title change and not on every `estimatedProgress` KVO tick during a load.
    private var lastTitles: [UUID: String] = [:]

    init(model: AppModel, factory: WebEngineFactory, badges: BadgeStore, icons: IconStore) {
        self.model = model
        self.factory = factory
        self.badges = badges
        self.icons = icons
    }

    // MARK: - Lifecycle

    /// Ensure an engine exists for `id`, make it current and mirror its state.
    func activate(_ id: UUID) {
        guard let app = model.apps.first(where: { $0.id == id }) else { return }
        let engine = engine(for: app)
        state.currentID = id
        mirror(engine.navState)
    }

    func view(for id: UUID) -> NSView? { engines[id]?.hostView }

    func reload(_ id: UUID) { engines[id]?.reload() }

    func discard(_ id: UUID) {
        engines[id]?.hostView.removeFromSuperview()
        engines[id] = nil
        lastTitles[id] = nil
        badges.clear(id)
        if state.currentID == id { state.currentID = nil }
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
        guard !text.isEmpty, let url = Self.url(fromOmnibox: text) else { return }
        if let current {
            current.load(url)
        } else {
            let app = model.addApp(title: url.displayHost ?? text, urlString: url.absoluteString)
            activate(app.id)
        }
    }

    static func url(fromOmnibox text: String) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text)
        }
        let looksLikeDomain = !text.contains(" ") && text.contains(".")
        if looksLikeDomain, let url = URL(string: "https://\(text)") {
            return url
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: "https://www.google.com/search?q=\(query)")
    }

    // MARK: - Private

    private var current: WebEngine? { state.currentID.flatMap { engines[$0] } }

    private func engine(for app: WebApp) -> WebEngine {
        if let existing = engines[app.id] { return existing }
        let engine = factory.makeEngine(for: app)
        let id = app.id
        // Every engine reports its nav state — foreground or not — so background
        // tabs keep their unread badge, rail title and icon current. Only the
        // foreground page drives the shared `BrowserState` the nav bar binds to.
        engine.onNavStateChange = { [weak self] nav in
            guard let self else { return }
            // Title-derived work (badge regex + rail title) only on a real title
            // change — `estimatedProgress` ticks repeat the same title otherwise.
            if self.lastTitles[id] != nav.title {
                self.lastTitles[id] = nav.title
                self.badges.update(id, fromTitle: nav.title)
                self.model.applyLiveTitle(id, to: nav.title)
            }
            // Sync the favicon only once the page has settled, so a redirect chain
            // doesn't fetch each hop's icon; `syncFavicon` no-ops unless the host
            // actually changed.
            if !nav.isLoading, let app = self.model.allTabs.first(where: { $0.id == id }) {
                self.icons.syncFavicon(app, pageURL: nav.url)
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
