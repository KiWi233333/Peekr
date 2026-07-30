import AppKit
import CefKit

/// Native child view used by the CefSwift windowed/Alloy browser. Browser
/// creation is deferred until the view belongs to a window because CEF requires
/// a live parent NSView; removing and re-adding the host preserves the browser.
@MainActor
final class CefSwiftBrowserHostView: NSView {
    weak var engine: CefSwiftEngine?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            engine?.attachBrowserIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        engine?.resizeBrowserView()
    }
}

/// Peekr's `WebEngine` adapter over CefSwift's public `CefBrowser` API.
///
/// CefSwift owns framework loading, CEF initialization, the external message
/// pump, helper processes and shutdown. This adapter only owns one browser,
/// translates its delegate events into Peekr's `NavState`, and exposes the
/// native view expected by `WebContainer`.
@MainActor
final class CefSwiftEngine: WebEngine {
    private let host = CefSwiftBrowserHostView()
    private let profile: CefProfile
    private var browser: CefBrowser?
    private var pendingURL: URL?
    private var faviconURLs: [URL] = []
    private var isClosed = false

    var hostView: NSView { host }
    private(set) var navState: NavState
    var onNavStateChange: ((NavState) -> Void)?

    init(url: URL?, profile: CefProfile) {
        self.profile = profile
        pendingURL = url
        var initialState = NavState()
        initialState.url = url
        navState = initialState
        host.engine = self
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        pendingURL = url
        browser?.load(url)
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }
    func stopLoading() { browser?.stopLoading() }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        browser?.delegate = nil
        browser?.close(force: true)
        browser = nil
        pendingURL = nil
        faviconURLs = []
    }

    func iconLinkURLs() async -> [URL] { faviconURLs }

    /// Create the CEF browser exactly once, at the first point the native host
    /// is attached to a real window.
    func attachBrowserIfNeeded() {
        guard !isClosed, browser == nil, host.window != nil else { return }

        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        options.profile = profile
        let initialURL = pendingURL ?? navState.url ?? URL(string: "about:blank")!
        let created = CefBrowser.createBrowser(
            parentView: host,
            bounds: host.bounds,
            url: initialURL,
            options: options,
            delegate: self
        )
        guard created.id >= 0 else {
            FileHandle.standardError.write(
                Data("Peekr: CefSwift failed to create a Chromium browser.\n".utf8)
            )
            applyLoading(false, canGoBack: false, canGoForward: false)
            return
        }

        browser = created
        pendingURL = nil
        resizeBrowserView()
    }

    func resizeBrowserView() {
        guard let native = browser?.nativeView else { return }
        if native.superview !== host {
            native.removeFromSuperview()
            host.addSubview(native)
        }
        if native.frame != host.bounds {
            native.frame = host.bounds
        }
        native.autoresizingMask = [.width, .height]
    }

    // MARK: - State translation

    func applyTitle(_ title: String) {
        updateNavState { $0.title = title }
    }

    func applyURL(_ url: URL?) {
        updateNavState { $0.url = url }
    }

    func applyLoading(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        updateNavState {
            $0.isLoading = loading
            $0.canGoBack = canGoBack
            $0.canGoForward = canGoForward
            if !loading { $0.progress = 1 }
        }
    }

    func applyProgress(_ progress: Double) {
        updateNavState { $0.progress = min(max(progress, 0), 1) }
    }

    private func updateNavState(_ update: (inout NavState) -> Void) {
        var next = navState
        update(&next)
        guard next != navState else { return }
        navState = next
        onNavStateChange?(next)
    }
}

extension CefSwiftEngine: CefBrowserDelegate {
    func browser(_ browser: CefBrowser, didChangeTitle title: String) {
        applyTitle(title)
    }

    func browser(_ browser: CefBrowser, didChangeURL url: URL?) {
        applyURL(url)
    }

    func browser(
        _ browser: CefBrowser,
        didChangeLoading isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        applyLoading(isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func browser(_ browser: CefBrowser, didChangeProgress progress: Double) {
        applyProgress(progress)
    }

    func browser(_ browser: CefBrowser, didChangeFavicon urls: [URL]) {
        faviconURLs = urls
    }

    func browser(
        _ browser: CefBrowser,
        didFailLoad code: Int,
        errorText: String,
        failedURL: String
    ) {
        applyLoading(false, canGoBack: browser.canGoBack, canGoForward: browser.canGoForward)
    }

    func browser(_ browser: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision {
        .openInSameBrowser
    }

    func browserDidClose(_ closedBrowser: CefBrowser) {
        if browser === closedBrowser {
            browser = nil
        }
        // A runtime-initiated close (including app termination) must not be
        // interpreted by a still-mounted host view as a request to recreate the
        // browser on its next layout/viewDidMoveToWindow callback.
        isClosed = true
        applyLoading(false, canGoBack: false, canGoForward: false)
    }
}

/// Chromium uses CefSwift's persistent global profile. CefSwift 0.1.0 places
/// named profiles two levels below CEF's root cache, but Chromium only accepts
/// profile directories that are direct children of that root. Using the
/// supported global context keeps logins persistent and browser creation
/// reliable until the upstream named-profile layout is corrected.
@MainActor
struct CefSwiftEngineFactory: WebEngineFactory {
    func makeEngine(for app: WebApp) -> WebEngine {
        CefSwiftEngine(url: app.url, profile: .default)
    }
}
