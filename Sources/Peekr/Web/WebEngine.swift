import AppKit

/// A snapshot of one page's navigation state, mirrored into `BrowserState`.
/// Engine-agnostic on purpose: WebKit reports it from KVO today, a future
/// Chromium/CEF engine reports the same shape from its own callbacks — so no
/// backend-specific types leak past the engine boundary.
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
/// `WKWebView` (or any future engine type) directly. Adding a second backend
/// means a new conformer plus a factory — nothing above this line changes.
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
}

/// Builds a `WebEngine` per dock app. The concrete factory picks the backend and
/// owns its setup (e.g. WebKit's per-app persistent data-store isolation), which
/// is the single seam a user-selectable engine would swap.
@MainActor
protocol WebEngineFactory {
    func makeEngine(for app: WebApp) -> WebEngine
}

/// The rendering backend the user picks in Preferences. `system` is the built-in
/// WebKit engine; `chromium` will download a CEF runtime on first use. Persisted
/// in `SettingsData`, so it must stay a stable raw string.
enum WebEngineKind: String, Codable, CaseIterable, Identifiable {
    case system, chromium
    var id: String { rawValue }

    /// Whether this engine can be offered/selected. Chromium requires the bundled
    /// native shim (a pure filesystem check, so it stays false under `swift run`,
    /// in tests, and in builds without Chromium support). The heavy framework may
    /// still need a first-use download even when this is true.
    var isAvailable: Bool {
        switch self {
        case .system: return true
        // Offerable iff the native shim is bundled. The shim path comes from
        // `CEFRuntime` (the single source) instead of a second copy of the
        // privateFrameworks lookup.
        case .chromium:
            guard let dylib = CEFRuntime.shimDylibURL?.path else { return false }
            return FileManager.default.fileExists(atPath: dylib)
        }
    }

    /// The concrete factory. Chromium resolves to the real CEF engine only when the
    /// shim is bundled, the runtime is downloaded, AND `CefInitialize` succeeds —
    /// otherwise it falls back to WebKit, so selecting Chromium can never break the
    /// app (worst case it renders with WebKit until the runtime is ready).
    @MainActor
    func makeFactory() -> WebEngineFactory {
        switch self {
        case .system:
            return WebKitEngineFactory()
        case .chromium:
            let rt = CEFRuntime.shared
            guard let lib = rt.lib, rt.isInstalled,
                  rt.ensureInitialized(frameworkDir: CEFRuntime.frameworkDir.path)
            else { return WebKitEngineFactory() }
            return CEFEngineFactory(makeBridge: { app in
                LibCEFBridge(lib: lib, url: app.url,
                             cacheDir: CEFRuntime.profileDir(for: app.id).path)
            })
        }
    }
}
