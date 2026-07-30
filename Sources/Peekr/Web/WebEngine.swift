import AppKit

/// A snapshot of one page's navigation state, mirrored into `BrowserState`.
/// Engine-agnostic on purpose: WebKit reports it from KVO behind the `WebEngine`
/// seam, so no backend-specific types leak past the engine boundary.
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
/// `WKWebView` directly. The seam keeps the UI backend-agnostic; adding a second
/// backend would mean a new conformer plus a factory — nothing above this changes.
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
    /// selected engine changes. WebKit needs no special shutdown; CEF must
    /// explicitly close its browser before the runtime can terminate.
    func close()

    /// The page's declared favicon `<link>` URLs read from the *live* DOM (already
    /// resolved to absolute). Reading the rendered DOM — not a second HTML fetch —
    /// captures icons that SPAs inject via JS. Empty when none are declared.
    func iconLinkURLs() async -> [URL]
}

extension WebEngine {
    func close() {}
}

/// Builds a `WebEngine` per dock app. The concrete factory owns the backend's
/// setup (e.g. WebKit's per-app persistent data-store isolation), which is the
/// single seam a second backend would swap.
@MainActor
protocol WebEngineFactory {
    func makeEngine(for app: WebApp) -> WebEngine
}

/// The rendering backend the user picks in Preferences. `system` is the built-in
/// WebKit engine; `chromium` is the CEF runtime bundled by CefSwift.
/// Persisted in `SettingsData`, so it must stay a stable raw string.
enum WebEngineKind: String, Codable, CaseIterable, Identifiable {
    case system, chromium
    var id: String { rawValue }

    /// Both backends ship in every supported Peekr bundle. CefSwift's bootstrap
    /// fails loudly at launch if its framework/helpers are missing, so Chromium
    /// never appears selectable while silently falling back to WebKit.
    var isAvailable: Bool { true }

    /// The concrete factory. Chromium is a direct CefSwift implementation: no
    /// runtime download, dlopen shim, or WebKit fallback.
    @MainActor
    func makeFactory() -> WebEngineFactory {
        switch self {
        case .system:
            return WebKitEngineFactory()
        case .chromium:
            return CefSwiftEngineFactory()
        }
    }
}
