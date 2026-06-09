import AppKit

/// The flat surface a libcef-backed shim must implement. `CEFEngine` talks only
/// to this, so the C++/ObjC++ libcef wiring (Stage 3: a hand-written shim over
/// the Chromium Embedded Framework — there is no maintained Swift binding) stays
/// isolated behind one protocol, and the engine logic above it is testable with a
/// fake. The shim reports navigation via `onNavState` from CEF's browser-process
/// UI thread, hopping to the main actor — the same `NavState` shape WebKit emits
/// from KVO, so nothing above the engine boundary is backend-specific.
@MainActor
protocol CEFBridge: AnyObject {
    /// The native view hosting the CEF browser, mounted into the panel.
    var view: NSView { get }
    /// Set by `CEFEngine`; the shim invokes it whenever navigation state changes.
    /// Each call MUST carry a COMPLETE NavState snapshot: `CEFEngine` replaces its
    /// `navState` wholesale and does not merge per field (unlike WebKitEngine's KVO
    /// fold), so a partial emit would zero out the omitted fields.
    var onNavState: ((NavState) -> Void)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
}

/// `WebEngine` backed by Chromium via `CEFBridge`. Structurally parallel to
/// `WebKitEngine` (which wraps `WKWebView`): it forwards navigation to the bridge
/// and mirrors the bridge's `NavState` out to `onNavStateChange`. The only thing
/// missing for a live engine is a concrete libcef-backed `CEFBridge` + a
/// `CEFEngineFactory` that builds one once the runtime is downloaded — both Stage 3.
@MainActor
final class CEFEngine: WebEngine {
    private let bridge: CEFBridge
    var hostView: NSView { bridge.view }
    private(set) var navState = NavState()
    var onNavStateChange: ((NavState) -> Void)?

    init(bridge: CEFBridge, url: URL?) {
        self.bridge = bridge
        bridge.onNavState = { [weak self] state in
            guard let self else { return }
            self.navState = state
            self.onNavStateChange?(state)
        }
        if let url { bridge.load(url) }
    }

    func load(_ url: URL) { bridge.load(url) }
    func goBack() { bridge.goBack() }
    func goForward() { bridge.goForward() }
    func reload() { bridge.reload() }
    func stopLoading() { bridge.stopLoading() }

    /// The CEF bridge exposes no JS evaluation, so live-DOM favicon links aren't
    /// available here; `IconStore` falls back to the standard favicon endpoints.
    func iconLinkURLs() async -> [URL] { [] }
}

/// Builds `CEFEngine`s. The libcef-backed bridge is injected via `makeBridge`, so
/// this conforms to `WebEngineFactory` exactly like `WebKitEngineFactory` while
/// keeping the C++ shim as the single remaining seam. Wiring this into
/// `WebEngineKind.chromium.makeFactory()` (and only when the runtime is installed)
/// is the last step, deferred until the shim and a downloaded runtime exist.
@MainActor
struct CEFEngineFactory: WebEngineFactory {
    /// Builds the per-app bridge. Like `WebKitEngineFactory` owns per-app
    /// `WKWebsiteDataStore` isolation, this seam must scope a per-app
    /// `CefRequestContext` (distinct cache path keyed on `app.id`) so each dock app
    /// keeps independent cookies/login — falling back to a shared context when
    /// `Bundle.main.bundleIdentifier` is nil (bare `swift run`).
    let makeBridge: (WebApp) -> CEFBridge

    func makeEngine(for app: WebApp) -> WebEngine {
        CEFEngine(bridge: makeBridge(app), url: app.url)
    }
}
