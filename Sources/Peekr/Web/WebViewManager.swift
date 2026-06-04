import AppKit
import WebKit

/// Creates and caches one WKWebView per app, keeping them alive across
/// show/hide so sessions, scroll position and playback are never lost.
/// Each app gets its own persistent data store → isolated cookies/logins.
/// Mirrors the active view's navigation state into `state` via KVO.
@MainActor
final class WebViewManager: NSObject {
    let state = BrowserState()

    private let model: AppModel
    private var views: [UUID: WKWebView] = [:]
    private var observations: [NSKeyValueObservation] = []

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: - Lifecycle

    /// Ensure a view exists for `id`, make it current and start mirroring state.
    func activate(_ id: UUID) {
        guard let app = model.apps.first(where: { $0.id == id }) else { return }
        let view = webView(for: app)
        state.currentID = id
        bindObservers(to: view)
    }

    func view(for id: UUID) -> WKWebView? { views[id] }

    func reload(_ id: UUID) { views[id]?.reload() }

    func discard(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
        if state.currentID == id { state.currentID = nil }
    }

    // MARK: - Navigation actions (operate on the active view)

    func goBack() { current?.goBack() }
    func goForward() { current?.goForward() }
    func reloadOrStop() {
        guard let current else { return }
        if current.isLoading {
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
            current.load(URLRequest(url: url))
        }
    }

    static func url(fromOmnibox text: String) -> URL? {
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
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

    private var current: WKWebView? { state.currentID.flatMap { views[$0] } }

    private func webView(for app: WebApp) -> WKWebView {
        if let existing = views[app.id] { return existing }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = makeDataStore(for: app.id)
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.setValue(false, forKey: "drawsBackground") // let glass show at edges
        if let url = app.url {
            view.load(URLRequest(url: url))
        }
        views[app.id] = view
        return view
    }

    private func bindObservers(to view: WKWebView) {
        observations.forEach { $0.invalidate() }
        observations = [
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                self?.state.canGoBack = wv.canGoBack
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                self?.state.canGoForward = wv.canGoForward
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                self?.state.isLoading = wv.isLoading
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                self?.state.progress = wv.estimatedProgress
            },
            view.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                self?.state.urlString = wv.url?.absoluteString ?? ""
            },
            view.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                self?.state.title = wv.title ?? ""
            }
        ]
    }

    /// Per-app persistent isolation needs a bundle identifier; fall back to the
    /// shared store when running the bare executable via `swift run`.
    private func makeDataStore(for id: UUID) -> WKWebsiteDataStore {
        if Bundle.main.bundleIdentifier != nil {
            return WKWebsiteDataStore(forIdentifier: id)
        }
        return .default()
    }
}
