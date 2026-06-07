/*
 * peekr_cef.h — the flat C ABI a libcef-backed shim must implement.
 *
 * This is the C-side half of the engine contract; the Swift side is the
 * `CEFBridge` protocol in Sources/Peekr/Web/CEFEngine.swift. A `LibCEFBridge:
 * CEFBridge` (Stage 3) calls these functions and forwards the nav callback into
 * `NavState`, so the whole panel/UI layer stays backend-agnostic.
 *
 * Why a C ABI and not C++ directly: Swift has no usable CEF binding and bridges
 * C cleanly but C++ only painfully. Keeping a flat `extern "C"` surface lets the
 * shim be implemented in ObjC++ (peekr_cef.mm) against CEF's C++ API while Swift
 * imports just this header via a module map.
 *
 * Built OUTSIDE SwiftPM (see cef-shim/README.md): SPM cannot assemble/sign CEF's
 * helper bundles, so the shim is a CMake target linking the downloaded Chromium
 * Embedded Framework. Nothing here is compiled by `swift build`.
 */
#ifndef PEEKR_CEF_H
#define PEEKR_CEF_H

#include <stdbool.h>

/* CEF is compiled with -fvisibility=hidden, so the shim's entry points must be
 * explicitly exported or the Swift side can't dlsym them. */
#define PEEKR_CEF_API __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque per-tab browser handle. */
typedef struct PeekrCEFBrowser PeekrCEFBrowser;

/* Navigation state pushed to Swift — mirrors Peekr's `NavState`. Passed as flat
 * scalars (not a by-value struct) so Swift can bind it via dlsym + @convention(c)
 * without depending on C struct layout. `url`/`title` are UTF-8 and borrowed for
 * the call only — copy them on the Swift side. `progress` is 0.0...1.0. */
typedef void (*PeekrCEFNavStateCallback)(void *userdata,
                                         bool can_go_back, bool can_go_forward,
                                         bool is_loading, double progress,
                                         const char *url, const char *title);

/* One-time runtime bootstrap: CefInitialize + helper-process paths. `framework_dir`
 * is the downloaded "Chromium Embedded Framework.framework" (see ChromiumRuntime).
 * Returns false if the runtime could not start. Call once per process, on the main
 * thread, before any create(). */
/* `helper_path` is the bundled "<App> Helper.app/Contents/MacOS/<exe>" the GPU/
 * renderer subprocesses launch from; pass NULL/"" to let CEF default to the main
 * executable (only valid if it handles CefExecuteProcess). */
/* `cache_root`:可写的缓存根目录,必须是每个 per-app request-context cache_path 的
 * 祖先(否则 CEF 拒绝该 cache_path)。务必放在 app 包之外(框架进包后包是只读/被密封
 * 的)——如 Application Support/Peekr/engines/chromium/profiles。传 NULL/"" 用 CEF 默认。 */
PEEKR_CEF_API bool peekr_cef_global_init(const char *framework_dir, const char *helper_path,
                                         const char *cache_root);

/* Per-app session isolation: a CEF request context with a private cache path —
 * the CEF analog of Peekr's per-app WKWebsiteDataStore(forIdentifier:). Pass the
 * app UUID string. */
PEEKR_CEF_API PeekrCEFBrowser *peekr_cef_create(void *parent_nsview,
                                                const char *cache_subdir,
                                                PeekrCEFNavStateCallback cb,
                                                void *userdata);
PEEKR_CEF_API void peekr_cef_destroy(PeekrCEFBrowser *browser);

PEEKR_CEF_API void peekr_cef_load(PeekrCEFBrowser *browser, const char *url);
PEEKR_CEF_API void peekr_cef_go_back(PeekrCEFBrowser *browser);
PEEKR_CEF_API void peekr_cef_go_forward(PeekrCEFBrowser *browser);
PEEKR_CEF_API void peekr_cef_reload(PeekrCEFBrowser *browser);
PEEKR_CEF_API void peekr_cef_stop(PeekrCEFBrowser *browser);

/* 把 windowed 浏览器尺寸调整到填满宿主 NSView。windowed CEF 在 CreateBrowser 时刻按
 * 父视图 bounds 创建——而宿主是 SwiftUI 刚创建、尚未布局的 NSView 时那是 0×0——且之后
 * 不会自己重新取尺寸,不调用本函数页面就一片空白。Swift 宿主在每次布局时把 bounds 推进来;
 * 若尺寸早于(异步的)浏览器创建到达,会被暂存并在 OnAfterCreated 套用。`w`/`h` 单位是点。 */
PEEKR_CEF_API void peekr_cef_resize(PeekrCEFBrowser *browser, int w, int h);

/* Drive one slice of CEF's message loop. Under external_message_pump the host
 * normally calls this from OnScheduleMessagePumpWork, but a host can also pump it
 * on a short repeating timer. */
PEEKR_CEF_API void peekr_cef_pump(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* PEEKR_CEF_H */
