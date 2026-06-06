// peekr_smoke.mm — minimal harness proving the shim drives a real CEF render.
// Creates an NSApp + window, inits CEF through the shim, opens a page, and logs
// every nav-state callback to a file. NOT part of the product — a build/runtime
// smoke test only. argv: <framework_dir> <helper_path> <cache_dir> <url> <logfile>

#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include "peekr_cef.h"

static FILE* g_log = stderr;

static void on_nav(void* userdata, bool can_go_back, bool can_go_forward,
                   bool is_loading, double progress, const char* url, const char* title) {
  (void)userdata; (void)progress;
  fprintf(g_log, "NAV loading=%d back=%d fwd=%d url=%s title=%s\n",
          is_loading, can_go_back, can_go_forward,
          url ? url : "", title ? title : "");
  fflush(g_log);
}

int main(int argc, char** argv) {
  @autoreleasepool {
    const char* framework = argc > 1 ? argv[1] : "";
    const char* helper    = argc > 2 ? argv[2] : "";
    const char* cache     = argc > 3 ? argv[3] : "/tmp/peekr-cef-cache";
    const char* url       = argc > 4 ? argv[4] : "https://example.com";
    if (argc > 5) { FILE* f = fopen(argv[5], "w"); if (f) g_log = f; }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    if (!peekr_cef_global_init(framework, helper)) {
      fprintf(g_log, "RESULT init=FAILED\n"); fflush(g_log);
      return 1;
    }
    fprintf(g_log, "RESULT init=OK\n"); fflush(g_log);

    NSRect frame = NSMakeRect(0, 0, 1024, 768);
    NSWindow* win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
          backing:NSBackingStoreBuffered defer:NO];
    [win center];
    [win makeKeyAndOrderFront:nil];

    PeekrCEFBrowser* browser = peekr_cef_create((__bridge void*)win.contentView, cache, on_nav, nullptr);
    fprintf(g_log, "RESULT create=%s\n", browser ? "OK" : "NULL"); fflush(g_log);
    if (browser) peekr_cef_load(browser, url);

    // Belt-and-suspenders: drive CEF's loop on a short timer (diagnoses whether
    // OnScheduleMessagePumpWork alone wasn't pumping).
    [NSTimer scheduledTimerWithTimeInterval:0.005 repeats:YES block:^(NSTimer*) {
      peekr_cef_pump();
    }];

    // Quit after 10s regardless, so the harness never hangs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)10 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
      fprintf(g_log, "RESULT done\n"); fflush(g_log);
      [NSApp terminate:nil];
    });
    [NSApp run];
  }
  return 0;
}
