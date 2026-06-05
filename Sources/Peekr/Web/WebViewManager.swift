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
    private var engines: [UUID: WebEngine] = [:]

    init(model: AppModel, factory: WebEngineFactory, badges: BadgeStore) {
        self.model = model
        self.factory = factory
        self.badges = badges
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
    func loadAddress(_ raw: String) {
        guard let current else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = Self.url(fromOmnibox: text) {
            current.load(url)
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
        // tabs keep their unread badge current. Only the foreground page drives
        // the shared `BrowserState` the nav bar binds to.
        engine.onNavStateChange = { [weak self] nav in
            guard let self else { return }
            self.badges.update(id, fromTitle: nav.title)
            if id == self.state.currentID { self.mirror(nav) }
        }
        engines[id] = engine
        return engine
    }

    private func mirror(_ nav: NavState) {
        state.canGoBack = nav.canGoBack
        state.canGoForward = nav.canGoForward
        state.isLoading = nav.isLoading
        state.progress = nav.progress
        state.urlString = nav.url?.absoluteString ?? ""
        state.title = nav.title
    }
}
