import AppKit

/// Loads the CEF shim (`libpeekr_cef.dylib`) at RUNTIME via `dlopen`, so the main
/// app never link-depends on it: Chromium is a pure opt-in and `swift run` /
/// WebKit are unaffected when the dylib isn't bundled. Resolves the flat C ABI
/// (`cef-shim/include/peekr_cef.h`) to typed Swift function pointers. `init?`
/// returns nil when the dylib or any symbol is missing — callers then fall back
/// to WebKit.
@MainActor
final class CEFLibrary {
    typealias NavCallback = @convention(c) (
        UnsafeMutableRawPointer?, Bool, Bool, Bool, Double,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    typealias InitFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Bool
    typealias CreateFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, NavCallback?, UnsafeMutableRawPointer?) -> OpaquePointer?
    typealias BrowserFn = @convention(c) (OpaquePointer?) -> Void
    typealias LoadFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias VoidFn = @convention(c) () -> Void

    let globalInit: InitFn
    let create: CreateFn
    let destroy: BrowserFn
    let load: LoadFn
    let goBack: BrowserFn
    let goForward: BrowserFn
    let reload: BrowserFn
    let stop: BrowserFn
    let pump: VoidFn

    init?(dylibPath: String) {
        guard let h = dlopen(dylibPath, RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ as: T.Type) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let i = sym("peekr_cef_global_init", InitFn.self),
            let c = sym("peekr_cef_create", CreateFn.self),
            let d = sym("peekr_cef_destroy", BrowserFn.self),
            let l = sym("peekr_cef_load", LoadFn.self),
            let b = sym("peekr_cef_go_back", BrowserFn.self),
            let f = sym("peekr_cef_go_forward", BrowserFn.self),
            let r = sym("peekr_cef_reload", BrowserFn.self),
            let s = sym("peekr_cef_stop", BrowserFn.self),
            let p = sym("peekr_cef_pump", VoidFn.self)
        else { dlclose(h); return nil }
        globalInit = i; create = c; destroy = d; load = l
        goBack = b; goForward = f; reload = r; stop = s; pump = p
    }
}

/// Owns the process-wide CEF runtime: dlopens the bundled shim once, runs the
/// one-time `CefInitialize` (after the framework is downloaded), and drives CEF's
/// message loop. Everything is failure-guarded — any miss leaves `engineFactory`
/// nil so `WebEngineKind.chromium` falls back to WebKit and the app never breaks.
@MainActor
final class CEFRuntime {
    static let shared = CEFRuntime()

    /// The shim dylib, dlopened from the app bundle's Frameworks. nil under
    /// `swift run` / when Chromium support wasn't bundled → Chromium unavailable.
    let lib: CEFLibrary?
    private var initialized = false
    private var pumpTimer: Timer?

    /// The bundled shim's expected location — nil under bare `swift run` (no
    /// Frameworks dir). The single source for "where the shim is", shared by the
    /// loader below and `WebEngineKind.isAvailable`, so the path isn't derived twice.
    nonisolated static var shimDylibURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("libpeekr_cef.dylib")
    }

    private init() {
        if let dylib = Self.shimDylibURL?.path,
           FileManager.default.fileExists(atPath: dylib) {
            lib = CEFLibrary(dylibPath: dylib)
        } else {
            lib = nil
        }
    }

    /// True when the native shim is present — i.e. Chromium can at least be offered
    /// (the heavy framework may still need downloading).
    var isSupported: Bool { lib != nil }

    /// The CEF version the bundled shim was compiled against — the downloaded
    /// framework MUST match (the wrapper ABI is version-locked).
    static let requiredVersion = "144.0.27"

    /// `…/Peekr/engines/chromium`, routed through `AppPaths` like every other
    /// Peekr location rather than re-deriving the app-support dir (which also
    /// avoids a force-unwrap on `urls(for:)` that would crash the "never break the
    /// app" fallback path).
    static var engineRoot: URL {
        AppPaths.supportDirectory.appendingPathComponent("engines/chromium", isDirectory: true)
    }
    static var layout: ChromiumRuntimeLayout { ChromiumRuntimeLayout(root: engineRoot) }
    static var installer: ChromiumRuntimeInstaller {
        ChromiumRuntimeInstaller(layout: layout, requiredVersion: requiredVersion,
                                 fileExists: { FileManager.default.fileExists(atPath: $0.path) })
    }
    /// The directory that CONTAINS "Chromium Embedded Framework.framework" once the
    /// runtime is installed — i.e. the version dir the archive extracts into.
    static var frameworkDir: URL { layout.versionDir(requiredVersion) }

    /// Per-app browsing profile (cookies/cache), kept OUTSIDE the versioned
    /// `frameworkDir` so a runtime upgrade or re-download — which replaces that dir
    /// wholesale (`ChromiumRuntimeFileInstaller` removes it before moving the new
    /// one in) — never wipes the user's logins. Keyed on the dock app's UUID, the
    /// CEF analog of WebKit's per-app `WKWebsiteDataStore(forIdentifier:)`.
    static func profileDir(for appID: UUID) -> URL {
        engineRoot.appendingPathComponent("profiles/\(appID.uuidString)", isDirectory: true)
    }

    /// Whether the matching framework is downloaded + installed.
    var isInstalled: Bool { Self.installer.isInstalled() }

    /// Bundled helper executable CEF spawns its subprocesses from.
    private var helperPath: String? {
        Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Peekr Helper.app/Contents/MacOS/Peekr Helper").path
    }

    /// One-time CefInitialize, pointed at the downloaded framework dir. Idempotent;
    /// returns false (→ WebKit fallback) if unsupported or init fails. Must run on
    /// the main thread with NSApp already up (it is, from AppDelegate).
    @discardableResult
    func ensureInitialized(frameworkDir: String) -> Bool {
        guard let lib else { return false }
        if initialized { return true }
        let ok = frameworkDir.withCString { fw in
            (helperPath ?? "").withCString { helper in lib.globalInit(fw, helper) }
        }
        if ok {
            initialized = true
            startPump()
        }
        return ok
    }

    /// Drive CEF's loop from the main run loop. ~120Hz is light and keeps nav/render
    /// responsive; CEF only does work when it has any. (Stage-3 refinement: switch
    /// to OnScheduleMessagePumpWork-only to idle at 0% CPU.)
    private func startPump() {
        guard let lib, pumpTimer == nil else { return }
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated { lib.pump() }
        }
    }
}

/// `CEFBridge` backed by the dlopened shim. Translates the flat C nav callback
/// into `NavState` and forwards navigation. Held by a `CEFEngine` for the tab's
/// lifetime.
@MainActor
final class LibCEFBridge: CEFBridge {
    let view = NSView()
    var onNavState: ((NavState) -> Void)?

    private let lib: CEFLibrary
    /// Captured at init so `deinit` (nonisolated) can tear down without touching
    /// the @MainActor `lib`. A C function pointer is Sendable and isolation-free.
    private let destroyFn: CEFLibrary.BrowserFn
    private var handle: OpaquePointer?

    init(lib: CEFLibrary, url: URL?, cacheDir: String) {
        self.lib = lib
        self.destroyFn = lib.destroy
        // FIXME(Stage 3): userdata is non-owning; a CEF callback after this bridge
        // deinits is a use-after-free. The engine keeps the bridge alive for the
        // tab's life and destroy() runs on teardown, so the window is small — but
        // the robust fix is to retain here and release from the shim's OnBeforeClose.
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        let cb: CEFLibrary.NavCallback = { ud, back, fwd, loading, progress, urlC, titleC in
            guard let ud else { return }
            let me = Unmanaged<LibCEFBridge>.fromOpaque(ud).takeUnretainedValue()
            var nav = NavState()
            nav.canGoBack = back
            nav.canGoForward = fwd
            nav.isLoading = loading
            nav.progress = progress
            nav.url = urlC.flatMap { URL(string: String(cString: $0)) }
            nav.title = titleC.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated { me.onNavState?(nav) }
        }
        let parent = Unmanaged.passUnretained(view).toOpaque()
        handle = cacheDir.withCString { lib.create(parent, $0, cb, userdata) }
        if let url { url.absoluteString.withCString { lib.load(handle, $0) } }
    }

    deinit { if let handle { destroyFn(handle) } }

    func load(_ url: URL) { url.absoluteString.withCString { lib.load(handle, $0) } }
    func goBack() { lib.goBack(handle) }
    func goForward() { lib.goForward(handle) }
    func reload() { lib.reload(handle) }
    func stopLoading() { lib.stop(handle) }
}
