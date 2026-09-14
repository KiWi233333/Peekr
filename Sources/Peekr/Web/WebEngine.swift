import AppKit

/// A snapshot of one page's navigation state, mirrored into `BrowserState`.
/// Engine-agnostic on purpose: backend-specific types never leak past this seam.
struct NavState: Equatable {
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var url: URL?
    var title = ""
}

/// One live web page for a dock app. The rendering backend lives entirely behind
/// this protocol, so `WebViewManager` and the whole panel/UI layer never touch
/// directly. The seam keeps the UI independent from CEF implementation details.
@MainActor
protocol WebEngine: AnyObject {
    /// The AppKit view `WebContainer` mounts into the panel.
    var hostView: NSView { get }
    /// Current navigation state; read on activation to seed the foreground UI.
    var navState: NavState { get }
    /// Nav-state callback. `WebViewManager` keeps it set on every engine — even
    /// background ones — so each tab's unread badge stays current; it mirrors to
    /// the shared `BrowserState` only for the engine whose id is foreground.
    var onNavStateChange: ((NavState) -> Void)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    /// Release backend resources immediately when a tab is discarded or the
    /// selected tab is discarded. CEF must explicitly close its browser before
    /// the runtime can terminate.
    func close()

    /// The page's declared favicon `<link>` URLs read from the *live* DOM (already
    /// resolved to absolute). Reading the rendered DOM — not a second HTML fetch —
    /// captures icons that SPAs inject via JS. Empty when none are declared.
    func iconLinkURLs() async -> [URL]
}

extension WebEngine {
    func close() {}
}

/// Builds a Chromium `WebEngine` per dock app. Keeping this small seam makes
/// lifecycle tests independent from the native CEF runtime.
@MainActor
protocol WebEngineFactory {
    func makeEngine(for app: WebApp) -> WebEngine
}
