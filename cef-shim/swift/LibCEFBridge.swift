// LibCEFBridge.swift — REFERENCE Swift wiring for the libcef shim.
//
// This is the concrete `CEFBridge` that calls the C ABI (peekr_cef.h) exposed by
// libpeekr_cef.dylib. It is kept HERE, outside Sources/, because compiling it
// needs a SwiftPM C target / module map for peekr_cef.h plus the built dylib —
// adding those to Package.swift before the shim exists would break `swift build`.
//
// To integrate (Stage 3 tail), once cef-shim builds:
//   1. Add a C target (e.g. `CPeekrCEF`) wrapping include/peekr_cef.h via a
//      module map, and link libpeekr_cef.dylib.
//   2. Move this file to Sources/Peekr/Web/ and `import CPeekrCEF`.
//   3. CEFEngineFactory(makeBridge: { LibCEFBridge(app: $0, cacheDir: …) }).
//   4. In WebEngineKind.chromium: return that factory from makeFactory() and flip
//      isAvailable to true only when ChromiumRuntimeInstaller.isInstalled().

#if canImport(CPeekrCEF)
import AppKit
import CPeekrCEF

/// `CEFBridge` backed by the libcef shim. Owns the opaque browser handle and
/// translates the C nav-state callback into Peekr's `NavState`.
@MainActor
final class LibCEFBridge: CEFBridge {
    let view = NSView()
    var onNavState: ((NavState) -> Void)?

    private var handle: OpaquePointer?

    /// `cacheDir` is the per-app isolated profile path, kept OUTSIDE the versioned
    /// runtime dir (engines/chromium/profiles/<app-uuid>) so a runtime upgrade
    /// doesn't wipe it. See `CEFRuntime.profileDir(for:)`.
    init(url: URL?, cacheDir: String) {
        // The C callback is a free function; pass `self` through `userdata` and
        // bounce back in.
        // FIXME(Stage 3): userdata is non-owning (passUnretained) here, so a CEF
        // nav callback that fires after this bridge deinits is a use-after-free.
        // Before compiling, retain self (passRetained) and release it from the
        // shim's OnBeforeClose — NOT from deinit, since CloseBrowser is async.
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        handle = view.withCEFParent { parent in
            peekr_cef_create(parent, cacheDir, { ud, state in
                guard let ud else { return }
                let me = Unmanaged<LibCEFBridge>.fromOpaque(ud).takeUnretainedValue()
                MainActor.assumeIsolated { me.emit(state) }
            }, userdata)
        }
        if let url { peekr_cef_load(handle, url.absoluteString) }
    }

    deinit { peekr_cef_destroy(handle) }

    private func emit(_ s: PeekrCEFNavState) {
        var nav = NavState()
        nav.canGoBack = s.can_go_back
        nav.canGoForward = s.can_go_forward
        nav.isLoading = s.is_loading
        nav.progress = s.progress
        nav.url = s.url.flatMap { URL(string: String(cString: $0)) }
        nav.title = s.title.map { String(cString: $0) } ?? ""
        onNavState?(nav)
    }

    func load(_ url: URL) { peekr_cef_load(handle, url.absoluteString) }
    func goBack() { peekr_cef_go_back(handle) }
    func goForward() { peekr_cef_go_forward(handle) }
    func reload() { peekr_cef_reload(handle) }
    func stopLoading() { peekr_cef_stop(handle) }
}

private extension NSView {
    /// Hand the NSView to C as the CEF parent (CefWindowHandle == NSView* on macOS).
    func withCEFParent<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T {
        body(Unmanaged.passUnretained(self).toOpaque())
    }
}
#endif
