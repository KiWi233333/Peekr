// peekr_cef.mm — libcef implementation of the flat C ABI in include/peekr_cef.h.
//
// First-cut implementation following CEF's canonical macOS embedding pattern
// (cefsimple/cefclient). It is built ONLY by cef-shim/CMakeLists.txt against a
// CEF SDK (CEF_ROOT) — never by `swift build`. It has NOT been compiled in this
// repo (no CEF SDK present); spots that are version-sensitive or need hardening
// are marked `VERIFY:`.
//
// Architecture notes:
//  - Peekr is an existing NSApplication, so CEF runs with an EXTERNAL message
//    pump (settings.external_message_pump) and we drive CefDoMessageLoopWork from
//    the main queue on OnScheduleMessagePumpWork — never CefRunMessageLoop, which
//    would take over the app's run loop.
//  - Per-app session isolation uses a CefRequestContext with its own cache_path,
//    the CEF analog of Peekr's per-app WKWebsiteDataStore(forIdentifier:).
//  - Multi-process is mandatory on macOS: the helper executables are a separate
//    target (peekr_helper.mm) pointed at by browser_subprocess_path.

#include "peekr_cef.h"

#import <Cocoa/Cocoa.h>
#include <string>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

// Drives CefDoMessageLoopWork on the main queue when CEF requests it, so CEF
// cooperates with the existing AppKit run loop instead of owning it.
class PeekrBrowserProcessHandler : public CefBrowserProcessHandler {
 public:
  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    // VERIFY: the int64_t signature matches your CEF branch (older branches use int64).
    // TODO(Stage 3): coalesce 0-delay requests — re-dispatching per call can
    // busy-spin the main queue under load; track a pending flag / cancel the
    // prior dispatch before scheduling the next.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay_ms * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
          CefDoMessageLoopWork();
        });
  }
  IMPLEMENT_REFCOUNTING(PeekrBrowserProcessHandler);
};

// Minimal CefApp for the browser process. The render/other processes use the
// separate helper target, so this only carries the browser-process handler.
class PeekrApp : public CefApp {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return browser_process_handler_;
  }

 private:
  CefRefPtr<CefBrowserProcessHandler> browser_process_handler_ =
      new PeekrBrowserProcessHandler();
  IMPLEMENT_REFCOUNTING(PeekrApp);
};

// One per browser. Mirrors navigation into a PeekrCEFNavState and pushes it to
// the Swift callback on the CEF UI thread (== main thread under external pump).
class PeekrClient : public CefClient,
                    public CefLifeSpanHandler,
                    public CefLoadHandler,
                    public CefDisplayHandler {
 public:
  PeekrClient(PeekrCEFNavStateCallback cb, void* userdata)
      : cb_(cb), userdata_(userdata) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  // Load now if the browser exists, else stash until OnAfterCreated — peekr_cef_load
  // is usually called right after create(), before CefBrowserHost::CreateBrowser
  // has asynchronously produced the browser, so an eager load would be dropped.
  void LoadURL(const std::string& url) {
    if (browser_) browser_->GetMainFrame()->LoadURL(url);
    else pending_url_ = url;
  }

  // CefLifeSpanHandler
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    if (!browser_) browser_ = browser;  // keep the top-level browser
    if (!pending_url_.empty()) {
      browser_->GetMainFrame()->LoadURL(pending_url_);
      pending_url_.clear();
    }
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (browser_ && browser_->IsSame(browser)) browser_ = nullptr;
  }

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    Emit(browser);
  }

  // CefDisplayHandler
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    Emit(browser);
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    title_ = title.ToString();
    Emit(browser);
  }

  CefRefPtr<CefBrowser> browser() const { return browser_; }

 private:
  void Emit(CefRefPtr<CefBrowser> browser) {
    if (!cb_ || !browser) return;
    const std::string url = browser->GetMainFrame()->GetURL().ToString();
    // CEF exposes no estimatedProgress; two-state approximation so the bar moves.
    cb_(userdata_, browser->CanGoBack(), browser->CanGoForward(),
        browser->IsLoading(), browser->IsLoading() ? 0.1 : 1.0,
        url.c_str(), title_.c_str());
  }

  PeekrCEFNavStateCallback cb_;
  void* userdata_;
  CefRefPtr<CefBrowser> browser_;
  std::string title_;
  std::string pending_url_;
  IMPLEMENT_REFCOUNTING(PeekrClient);
};

}  // namespace

// Opaque handle handed back to Swift.
struct PeekrCEFBrowser {
  CefRefPtr<PeekrClient> client;
  CefRefPtr<CefRequestContext> request_context;
};

bool peekr_cef_global_init(const char* framework_dir, const char* helper_path) {
  @autoreleasepool {
    // `framework_dir` is the directory CONTAINING the framework (it lives under
    // Application Support, not the app bundle). dlopen the framework binary;
    // cef_load_library binds the wrapper's symbols against it.
    const std::string fw = std::string(framework_dir) + "/Chromium Embedded Framework.framework";
    if (!cef_load_library((fw + "/Chromium Embedded Framework").c_str())) return false;

    CefMainArgs main_args(0, nullptr);
    CefSettings settings;
    settings.external_message_pump = true;  // cooperate with NSApp's run loop
    settings.no_sandbox = true;             // TODO(Stage 3): enable sandbox once helpers are bundled+signed
    // A per-app root cache avoids the shared-default-dir process singleton (CEF
    // hands a 2nd launch off to the 1st and exits). Real app: Application Support/Peekr/cef.
    CefString(&settings.root_cache_path).FromString("/tmp/peekr-cef-root");
    // Point CEF at the framework + its bundled resources (icudtl.dat, *.pak,
    // locales) explicitly — without a host .app bundle CEF can't auto-locate them.
    CefString(&settings.framework_dir_path).FromString(fw);
    CefString(&settings.resources_dir_path).FromString(fw + "/Resources");
    CefString(&settings.locales_dir_path).FromString(fw + "/Resources");
    // The bundled helper executable the GPU/renderer subprocesses launch from.
    if (helper_path && helper_path[0]) {
      CefString(&settings.browser_subprocess_path).FromString(helper_path);
    }

    CefRefPtr<PeekrApp> app = new PeekrApp();
    return CefInitialize(main_args, settings, app.get(), nullptr);
  }
}

PeekrCEFBrowser* peekr_cef_create(void* parent_nsview,
                                  const char* cache_subdir,
                                  PeekrCEFNavStateCallback cb,
                                  void* userdata) {
  @autoreleasepool {
    auto* handle = new PeekrCEFBrowser();
    handle->client = new PeekrClient(cb, userdata);

    // Per-app isolation: a request context with its own on-disk cache, the CEF
    // analog of WKWebsiteDataStore(forIdentifier:).
    CefRequestContextSettings rc_settings;
    CefString(&rc_settings.cache_path)
        .FromString(std::string(cache_subdir));  // absolute path from Swift
    handle->request_context =
        CefRequestContext::CreateContext(rc_settings, nullptr);

    NSView* parent = (__bridge NSView*)parent_nsview;
    CefWindowInfo window_info;
    // On macOS CefWindowHandle is an NSView*; host the browser as its child.
    window_info.SetAsChild((__bridge void*)parent,
                           CefRect(0, 0, (int)parent.bounds.size.width,
                                   (int)parent.bounds.size.height));
    // VERIFY: SetAsChild's signature differs across branches (CefRect vs
    // CefWindowHandle+CefRect). Match your CEF version's cef_types_mac.h.

    CefBrowserSettings browser_settings;
    CefBrowserHost::CreateBrowser(window_info, handle->client,
                                  CefString(""),  // load() drives the first URL
                                  browser_settings, nullptr,
                                  handle->request_context);
    return handle;
  }
}

void peekr_cef_destroy(PeekrCEFBrowser* browser) {
  if (!browser) return;
  if (auto b = browser->client ? browser->client->browser() : nullptr) {
    b->GetHost()->CloseBrowser(/*force_close=*/true);
  }
  delete browser;  // CefRefPtr members release here
}

static CefRefPtr<CefBrowser> live(PeekrCEFBrowser* b) {
  return (b && b->client) ? b->client->browser() : nullptr;
}

void peekr_cef_load(PeekrCEFBrowser* browser, const char* url) {
  if (browser && browser->client && url) browser->client->LoadURL(url);
}
void peekr_cef_go_back(PeekrCEFBrowser* browser) {
  if (auto b = live(browser)) b->GoBack();
}
void peekr_cef_go_forward(PeekrCEFBrowser* browser) {
  if (auto b = live(browser)) b->GoForward();
}
void peekr_cef_reload(PeekrCEFBrowser* browser) {
  if (auto b = live(browser)) b->Reload();
}
void peekr_cef_stop(PeekrCEFBrowser* browser) {
  if (auto b = live(browser)) b->StopLoad();
}

void peekr_cef_pump() { CefDoMessageLoopWork(); }
