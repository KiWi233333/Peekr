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
    /// Live OAuth / `window.open` popups, retained until they close themselves.
    private var popups: [PopupController] = []

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

    private var current: WKWebView? { state.currentID.flatMap { views[$0] } }

    private func webView(for app: WebApp) -> WKWebView {
        if let existing = views[app.id] { return existing }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = makeDataStore(for: app.id)
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        // Allow OAuth flows to spawn their popup after a redirect, not just on the
        // initial click gesture.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        // Handle `window.open` / `target="_blank"`; without a UI delegate WebKit
        // silently drops them, making "Continue with Google"-style buttons dead.
        view.uiDelegate = self
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
            bind(view, \.canGoBack) { $0.canGoBack = $1 },
            bind(view, \.canGoForward) { $0.canGoForward = $1 },
            bind(view, \.isLoading) { $0.isLoading = $1 },
            bind(view, \.estimatedProgress) { $0.progress = $1 },
            bind(view, \.url) { $0.urlString = $1?.absoluteString ?? "" },
            bind(view, \.title) { $0.title = $1 ?? "" }
        ]
    }

    /// Observe a WKWebView key path and mirror it into `state` on the main actor.
    /// WKWebView posts these KVO notifications on the main thread already.
    private func bind<Value: Sendable>(
        _ view: WKWebView,
        _ keyPath: KeyPath<WKWebView, Value>,
        apply: @escaping @MainActor (BrowserState, Value) -> Void
    ) -> NSKeyValueObservation {
        view.observe(keyPath, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self.state, value)
            }
        }
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

// MARK: - Popups (OAuth / window.open)

extension WebViewManager: WKUIDelegate {
    /// WebKit asks for a new web view when a page calls `window.open` or a link
    /// has `target="_blank"`. Returning nil (the default with no UI delegate)
    /// silently drops it — which is why third-party login buttons looked dead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A *sized* window.open() is an auth/OAuth popup. Open a real child
        // window built from the configuration WebKit hands us, so it shares the
        // opener's process and data store: the login lands in this app's
        // isolated session, and window.opener / postMessage / window.close()
        // keep working — exactly what the OAuth handshake needs.
        if windowFeatures.width != nil || windowFeatures.height != nil {
            let popup = PopupController(configuration: configuration,
                                       features: windowFeatures) { [weak self] dead in
                self?.popups.removeAll { $0 === dead }
            }
            popups.append(popup)
            return popup.webView
        }

        // Plain target="_blank" → navigate in place rather than spawning a window.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

/// A standalone window hosting an OAuth / `window.open` popup. Built from the
/// configuration WebKit supplies so it shares the opener's process and data
/// store; retained by `WebViewManager.popups` until it closes itself.
@MainActor
private final class PopupController: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private let onClose: (PopupController) -> Void

    init(
        configuration: WKWebViewConfiguration,
        features: WKWindowFeatures,
        onClose: @escaping (PopupController) -> Void
    ) {
        self.onClose = onClose
        let width = features.width?.doubleValue ?? 600
        let height = features.height?.doubleValue ?? 720
        let rect = NSRect(x: 0, y: 0, width: width, height: height)

        webView = WKWebView(frame: rect, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered,
                          defer: false)
        super.init()

        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        webView.uiDelegate = self
        webView.navigationDelegate = self

        // The auth flow needs keyboard focus (typing a password), so bring the
        // app forward — unlike the peek panel, which deliberately never steals
        // focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Show the provider's page title in the window's titlebar.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.title = webView.title ?? ""
    }

    /// A provider popup may chain to another (e.g. account picker → consent);
    /// keep the chain inside this one window.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    /// OAuth providers call window.close() once the handshake is done.
    func webViewDidClose(_ webView: WKWebView) { window.close() }

    /// Both paths — JS window.close() and the user clicking the red button —
    /// funnel here, so the manager drops its reference exactly once.
    func windowWillClose(_ notification: Notification) { onClose(self) }
}
