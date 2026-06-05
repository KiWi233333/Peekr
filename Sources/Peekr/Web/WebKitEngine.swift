import AppKit
import WebKit

/// `WebEngine` backed by `WKWebView` — the default, system-provided backend.
/// Owns its view for life so sessions/scroll/playback survive show/hide; mirrors
/// nav state out of KVO and handles OAuth / `window.open` popups.
@MainActor
final class WebKitEngine: NSObject, WebEngine {
    let webView: NavigatingWebView
    var hostView: NSView { webView }
    private(set) var navState = NavState()
    var onNavStateChange: ((NavState) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    /// Live OAuth / `window.open` popups, retained until they close themselves.
    private var popups: [PopupController] = []

    /// The app's start page and the last committed URL — both nil-safe anchors
    /// for reloading after the content process is jettisoned (see terminate).
    private let homeURL: URL?
    private var lastURL: URL?

    /// `configuration` carries the per-app data store the factory built; page
    /// preferences shared by every WebKit page are applied here.
    init(configuration: WKWebViewConfiguration, url: URL?) {
        homeURL = url
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        // Allow OAuth flows to spawn their popup after a redirect, not just on the
        // initial click gesture.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = NavigatingWebView(frame: .zero, configuration: configuration)
        super.init()

        // Mouse thumb buttons (button 3 = back, 4 = forward) — WKWebView ignores
        // them by default, so wire them to history navigation like every browser.
        webView.onBack = { [weak self] in self?.goBack() }
        webView.onForward = { [weak self] in self?.goForward() }
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Handle `window.open` / `target="_blank"`; without a UI delegate WebKit
        // silently drops them, making "Continue with Google"-style buttons dead.
        webView.uiDelegate = self
        // Recover kept-alive tabs whose content process the system jettisons under
        // memory pressure while backgrounded (see webViewWebContentProcessDidTerminate).
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // let glass show at edges
        bindObservers()
        if let url { webView.load(URLRequest(url: url)) }
    }

    // MARK: - Navigation

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    // MARK: - State mirroring

    private func bindObservers() {
        observations = [
            observe(\.canGoBack) { $0.canGoBack = $1 },
            observe(\.canGoForward) { $0.canGoForward = $1 },
            observe(\.isLoading) { $0.isLoading = $1 },
            observe(\.estimatedProgress) { $0.progress = $1 },
            observe(\.url) { $0.url = $1 },
            observe(\.title) { $0.title = $1 ?? "" }
        ]
    }

    /// Observe a WKWebView key path, fold it into `navState`, and push to the
    /// foreground sink. WKWebView posts these KVO notifications on the main
    /// thread already, so the actor hop is just an assertion.
    private func observe<Value: Sendable>(
        _ keyPath: KeyPath<WKWebView, Value>,
        apply: @escaping (inout NavState, Value) -> Void
    ) -> NSKeyValueObservation {
        (webView as WKWebView).observe(keyPath, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(&self.navState, value)
                self.onNavStateChange?(self.navState)
            }
        }
    }
}

/// `WKWebView` that maps the mouse thumb buttons to history navigation.
/// WebKit's content view doesn't consume `otherMouseDown` for buttons 3/4, so
/// AppKit walks them up the responder chain to here — overriding on the subview
/// would be unreachable. Buttons are fixed by the HID spec: 3 = back, 4 = forward.
final class NavigatingWebView: WKWebView {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: onBack?()
        case 4: onForward?()
        default: super.otherMouseDown(with: event)
        }
    }
}

// MARK: - Process keep-alive

extension WebKitEngine: WKNavigationDelegate {
    /// Remember where each tab actually is, so a reload after a process crash
    /// lands on the page the user was on — not the start page.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { lastURL = url }
    }

    /// The Web Content process was jettisoned — almost always because the system
    /// reclaimed memory while this cached tab was backgrounded (the panel hidden
    /// or another app active). WebKit leaves the view blank and `url` nil; without
    /// this the next peek shows an empty page, silently breaking keep-alive. Reload
    /// the last location so the tab restores itself transparently.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let target = webView.url ?? lastURL ?? homeURL {
            webView.load(URLRequest(url: target))
        }
    }
}

// MARK: - Popups (OAuth / window.open)

extension WebKitEngine: WKUIDelegate {
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
/// store; retained by `WebKitEngine.popups` until it closes itself.
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

/// Default factory: builds `WebKitEngine`s and owns WebKit's per-app data-store
/// isolation. This is the seam a user-selectable backend would swap.
struct WebKitEngineFactory: WebEngineFactory {
    func makeEngine(for app: WebApp) -> WebEngine {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.makeDataStore(for: app.id)
        return WebKitEngine(configuration: config, url: app.url)
    }

    /// Per-app persistent isolation needs a bundle identifier; fall back to the
    /// shared store when running the bare executable via `swift run`.
    private static func makeDataStore(for id: UUID) -> WKWebsiteDataStore {
        Bundle.main.bundleIdentifier != nil
            ? WKWebsiteDataStore(forIdentifier: id)
            : .default()
    }
}
