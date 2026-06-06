# cef-shim — the Chromium (CEF) backend's native shim (Stage 3)

This directory holds the **C++/ObjC++ shim** that backs Peekr's optional Chromium
engine. It is built **outside** SwiftPM (CMake), because SPM cannot assemble or
codesign CEF's mandatory helper-app bundles. `swift build` / `swift test` never
touch this directory, so the main app stays a clean single SPM target.

## Where this fits

The engine is layered so the only un-written piece is the libcef body:

```
WebViewManager ──▶ WebEngine (protocol)        ✅ done
                     └─ CEFEngine               ✅ done + tested (Swift)
                          └─ CEFBridge (protocol) ✅ done  ← Swift seam
                               └─ peekr_cef.h       ✅ done  ← C ABI contract (this dir)
                                    └─ peekr_cef.mm  ✅ builds + runs (CEF 144) — see below
```

## Build & run — VERIFIED working (2026-06-05)

Built and run against **CEF 144.0.27 / Chromium 144** (`macosarm64_minimal`), macOS 26, arm64.

```bash
# 1. SDK: download cef_binary_..._macosarm64_minimal.tar.bz2 from
#    https://cef-builds.spotifycdn.com and extract it; export CEF_ROOT to it.
# 2. Build the shim + helper + smoke harness:
brew install cmake
cmake -B cef-shim/build -DCEF_ROOT="$CEF_ROOT" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DUSE_SANDBOX=OFF
cmake --build cef-shim/build -j
# 3. One-shot smoke (run from YOUR GUI session — opens a window, renders a page):
CEF_ROOT="$CEF_ROOT" ./cef-shim/smoke.sh https://example.com
```

**Empirically verified** (the part long deemed a multi-week blocker):
- The hand-written `peekr_cef.mm` / `peekr_helper.mm` **compile + link + export** the C ABI
  against real CEF 144 under `-Wall -Werror` (one benign `-pie` warning).
- `dlopen` + `dlsym` of `libpeekr_cef.dylib` works — exactly the Swift path.
- `cef_load_library` loads the framework; **`CefInitialize` succeeds** and a **browser is
  created**; CEF spawns its **multi-process subprocesses** (GPU + NetworkService) from the
  bundled `Peekr Helper.app`.

Hard-won build details (don't regress these):
- `-DUSE_SANDBOX=OFF` to match `settings.no_sandbox = true` (sandbox is Stage-3 work).
- CEF compiles with `-fvisibility=hidden`, so the C ABI is marked `PEEKR_CEF_API`
  (`visibility("default")`) or Swift can't `dlsym` it.
- The framework is loaded at RUNTIME (`cef_load_library`), never link-time; set
  `framework_dir_path` / `resources_dir_path` / `locales_dir_path` explicitly (no host
  `.app` to auto-locate them) and a per-app `root_cache_path` (else CEF's process
  singleton hands a 2nd launch off to the 1st).
- `peekr_cef_load` stashes the URL until `OnAfterCreated` — `CreateBrowser` is async, so
  an eager load right after `create()` is dropped.

Still to do for an in-Peekr render: drive it from Peekr's owned `NSApp` run loop (a
detached `open` from an agent shell doesn't get a usable window server), wire the Swift
`dlopen` bridge, bundle+sign helpers into `Peekr.app`, and host the runtime for download.

Runtime delivery is already built and tested on the Swift side
(`Sources/Peekr/Web/ChromiumRuntime*.swift`): the heavy (~180 MB) Chromium
Embedded Framework is **downloaded on first use**, SHA-256-verified, and installed
under `~/Library/Application Support/Peekr/engines/chromium/<version>/`. The shim
links CEF; `peekr_cef_global_init(framework_dir)` points it at that downloaded
framework.

## Remaining work (the genuinely hard part)

1. **Implement `peekr_cef.mm`** against the CEF C++ API: a `CefApp` +
   `CefClient` with `CefLifeSpanHandler` / `CefLoadHandler` / `CefDisplayHandler`,
   pushing `PeekrCEFNavState` from `OnLoadingStateChange` / `OnAddressChange` /
   `OnTitleChange`. Create the browser windowless-or-NSView-hosted via
   `CefBrowserHost::CreateBrowser` into `parent_nsview`. Re-derive Peekr behaviors
   WKWebView gave for free: non-activating panel focus, transparent background for
   the glass edges, `window.open`/OAuth popups, content keep-alive across show/hide.
2. **Obtain a CEF distribution** (arm64 + x86_64) — e.g. the Spotify CDN builds —
   matching the version the app downloads at runtime. Host it + a signed
   `ChromiumRuntimeManifest` JSON (`version` / `url` / `sha256` / `sizeBytes`) for
   `ChromiumRuntimeDownloader` to fetch.
3. **CMake build** → `libpeekr_cef.dylib` + the 4–5 `*Helper.app` bundles
   (GPU / Renderer / Plugin / Alerts), in CEF's mandated bundle layout.
4. **Sign the helpers inside-out** with the JIT entitlements
   (`com.apple.security.cs.allow-jit`, `allow-unsigned-executable-memory`,
   `disable-library-validation`) — the extension point is already marked in
   `scripts/bundle.sh`. The main app's hardened-runtime signing + notarization is
   **already wired** (gated) in `bundle.sh` / `notarize.sh` / `release.yml`.

## Wiring it back into Swift (Stage 3 tail)

1. Add a SwiftPM C target exposing `peekr_cef.h` via a module map (or link the
   prebuilt `libpeekr_cef.dylib`).
2. Implement `LibCEFBridge: CEFBridge` calling the C ABI and translating
   `PeekrCEFNavState` → `NavState`.
3. `CEFEngineFactory(makeBridge: { LibCEFBridge(app: $0) })` — the factory already
   exists and is tested with a fake bridge.
4. In `WebEngineKind.chromium`: return `CEFEngineFactory` from `makeFactory()` and
   flip `isAvailable` to true **only when `ChromiumRuntimeInstaller.isInstalled()`**;
   otherwise route the Preferences "Chromium" row to the download flow.

> Effort for step 1 (the `.mm` body + bundling + helper signing): ~8–16 person-weeks
> of senior macOS/C++ work, plus an ongoing ~monthly re-validation tax to track
> upstream Chromium security. This is why the Chromium engine is a power-user,
> opt-in, download-on-first-use backend — never the default — to protect the
> lightweight/native moat.

## Known issues to fix before it compiles/ships (from an adversarial review)

The first-cut `.mm`/Swift here was reviewed but not compiled (no CEF SDK). Resolve
these when wiring Stage 3 — each was verified as real, just deferred until the
shim actually builds:

1. **Loader bootstrap is incoherent (won't compile).** `peekr_cef_global_init`
   does `new cef_scoped_library_loader_t()` (not a real CEF type) *and* a separate
   `cef_load_library(...)`. Use ONE mechanism: a file-scope
   `static CefScopedLibraryLoader g_loader; g_loader.LoadInMain();` (process-lifetime
   RAII, no `new`) — the idiom `peekr_helper.mm` already uses with `LoadInHelper()`.
2. **userdata use-after-free.** `LibCEFBridge` passes `passUnretained(self)`; a CEF
   nav callback after deinit dereferences freed memory. Retain (`passRetained`) at
   create and release from the shim's `OnBeforeClose` (already FIXME'd in the file).
3. **Synchronous teardown after async close.** `peekr_cef_destroy` `delete`s right
   after `CloseBrowser(force_close:true)`, which is async. Set the client callback
   to null, request close, and free the handle / release the Swift ref from
   `OnBeforeClose`, not synchronously.
4. **No resize path → browser may render at 0×0.** The view is created before
   layout (`parent.bounds` ≈ zero) and nothing ever calls `CefBrowserHost::WasResized`.
   Add `peekr_cef_resize(browser, w, h)` to the C ABI and call it when the host
   NSView's frame changes.
5. **`browser_subprocess_path` is commented out** → helpers won't spawn. Resolve the
   `*Helper.app` executable path at runtime and set it in `CefSettings`.
6. **`SetAsChild` signature is branch-sensitive** — confirm against the pinned CEF
   version's `cef_types_mac.h` (already marked `VERIFY:`).
