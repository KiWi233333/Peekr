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
PEEKR_CEF_API bool peekr_cef_global_init(const char *framework_dir, const char *helper_path);

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

/* Drive one slice of CEF's message loop. Under external_message_pump the host
 * normally calls this from OnScheduleMessagePumpWork, but a host can also pump it
 * on a short repeating timer. */
PEEKR_CEF_API void peekr_cef_pump(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* PEEKR_CEF_H */
