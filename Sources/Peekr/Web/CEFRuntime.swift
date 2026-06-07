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
    typealias InitFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Bool
    typealias CreateFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, NavCallback?, UnsafeMutableRawPointer?) -> OpaquePointer?
    typealias BrowserFn = @convention(c) (OpaquePointer?) -> Void
    typealias LoadFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias ResizeFn = @convention(c) (OpaquePointer?, Int32, Int32) -> Void
    typealias VoidFn = @convention(c) () -> Void

    let globalInit: InitFn
    let create: CreateFn
    let destroy: BrowserFn
    let load: LoadFn
    let resize: ResizeFn
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
            let rs = sym("peekr_cef_resize", ResizeFn.self),
            let b = sym("peekr_cef_go_back", BrowserFn.self),
            let f = sym("peekr_cef_go_forward", BrowserFn.self),
            let r = sym("peekr_cef_reload", BrowserFn.self),
            let s = sym("peekr_cef_stop", BrowserFn.self),
            let p = sym("peekr_cef_pump", VoidFn.self)
        else { dlclose(h); return nil }
        globalInit = i; create = c; destroy = d; load = l; resize = rs
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
    /// 含 "Chromium Embedded Framework.framework" 的目录。优先用包内副本
    /// (Contents/Frameworks):macOS 只为「被密封进 app 包」的代码派生代码签名
    /// validation category,而 Chromium 144 要靠这个 category 才能启动 renderer 子进程——
    /// 从 Application Support dlopen 的框架会让进程自校验失败(errSecCSReqFailed),
    /// renderer 一个都起不来。包内没有时回退到下载的版本目录。
    static var frameworkDir: URL {
        if let fw = bundledFrameworkURL, FileManager.default.fileExists(atPath: fw.path) {
            return fw.deletingLastPathComponent()
        }
        return layout.versionDir(requiredVersion)
    }

    /// 随包发布时框架的包内位置(Contents/Frameworks/Chromium Embedded Framework.framework)。
    nonisolated static var bundledFrameworkURL: URL? {
        Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Chromium Embedded Framework.framework")
    }

    /// root_cache_path:per-app profile 的可写父目录(profiles/<uuid> 是其直接子目录)。
    /// 必须独立于 frameworkDir——框架进包后那是只读的,不能再当缓存根。
    static var cacheRoot: URL {
        engineRoot.appendingPathComponent("profiles", isDirectory: true)
    }

    /// Per-app browsing profile (cookies/cache), kept OUTSIDE the versioned
    /// `frameworkDir` so a runtime upgrade or re-download — which replaces that dir
    /// wholesale (`ChromiumRuntimeFileInstaller` removes it before moving the new
    /// one in) — never wipes the user's logins. Keyed on the dock app's UUID, the
    /// CEF analog of WebKit's per-app `WKWebsiteDataStore(forIdentifier:)`.
    static func profileDir(for appID: UUID) -> URL {
        engineRoot.appendingPathComponent("profiles/\(appID.uuidString)", isDirectory: true)
    }

    /// 框架是否就位:随包发布在包内,或已下载到 Application Support——两种都看
    /// `frameworkDir` 下框架是否存在,而不再只认下载完成标记。
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath:
            Self.frameworkDir.appendingPathComponent("Chromium Embedded Framework.framework").path)
    }

    /// Bundled helper executable CEF spawns its subprocesses from.
    private var helperPath: String? {
        Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Peekr Helper.app/Contents/MacOS/Peekr Helper").path
    }

    /// 一次性 CefInitialize,指向框架目录 + 可写缓存根。幂等;不支持或初始化失败时返回
    /// false(→ 回退 WebKit)。必须在主线程、NSApp 已起来后调用(AppDelegate 满足)。
    @discardableResult
    func ensureInitialized(frameworkDir: String) -> Bool {
        guard let lib else { return false }
        if initialized { return true }
        // 缓存根在 Application Support 下、可能尚不存在;CEF 不会自建,先确保它在。
        try? FileManager.default.createDirectory(at: Self.cacheRoot, withIntermediateDirectories: true)
        let cacheRoot = Self.cacheRoot.path
        let ok = frameworkDir.withCString { fw in
            (helperPath ?? "").withCString { helper in
                cacheRoot.withCString { cache in lib.globalInit(fw, helper, cache) }
            }
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
    /// windowed CEF 会在这个视图里挂一个子 NSView,但从不主动重新取尺寸,所以我们把每次
    /// 布局变化都转发给 `peekr_cef_resize`。没有它浏览器就停在 0×0 创建尺寸、渲染空白。
    private let host = CEFHostView()
    var view: NSView { host }
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
        let parent = Unmanaged.passUnretained(host).toOpaque()
        handle = cacheDir.withCString { lib.create(parent, $0, cb, userdata) }
        // 把布局驱动的尺寸变化转发给 CEF。若在异步浏览器创建前到达,shim 侧会暂存并在创建时套用。
        host.onResize = { [weak self] w, h in
            guard let self, let handle = self.handle else { return }
            self.lib.resize(handle, Int32(w), Int32(h))
        }
        let b = host.bounds
        if b.width > 0, b.height > 0 { lib.resize(handle, Int32(b.width), Int32(b.height)) }
        if let url { url.absoluteString.withCString { lib.load(handle, $0) } }
    }

    deinit { if let handle { destroyFn(handle) } }

    func load(_ url: URL) { url.absoluteString.withCString { lib.load(handle, $0) } }
    func goBack() { lib.goBack(handle) }
    func goForward() { lib.goForward(handle) }
    func reload() { lib.reload(handle) }
    func stopLoading() { lib.stop(handle) }
}

/// windowed CEF 子视图的宿主:把自身尺寸上报给 shim,让 CEF 调用 `WasResized`、Chromium
/// 才会创建 render widget(尺寸为 0 时不 spawn renderer、页面空白)。NSView 的几何变化会经
/// 多条路径到达——`frame=`(setFrame:)、autoresizing、进入窗口——而 `setFrame:` 不一定走
/// `setFrameSize:`,所以每条路径都重写。`report()` 只是推当前 bounds;shim 对重复尺寸是
/// no-op,所以多报无害,关键是覆盖全。
final class CEFHostView: NSView {
    var onResize: ((CGFloat, CGFloat) -> Void)?

    override var frame: NSRect {
        get { super.frame }
        set { super.frame = newValue; report() }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); report() }
    override func layout() { super.layout(); report() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }

    private func report() {
        let b = bounds
        if b.width > 0, b.height > 0 { onResize?(b.width, b.height) }
    }
}
