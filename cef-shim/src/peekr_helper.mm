// peekr_helper.mm — entry point for the CEF helper subprocesses.
//
// macOS Chromium is multi-process and the single-process model is unsupported,
// so the app MUST ship separate helper executables (GPU / Renderer / Plugin /
// Alerts), each wrapped in its own *Helper.app bundle and pointed at by the
// browser process's browser_subprocess_path. This one tiny binary backs all of
// them; the bundle's Info.plist + entitlements differentiate the process types.
//
// Built by cef-shim/CMakeLists.txt against the CEF SDK; never by `swift build`.

#import <Cocoa/Cocoa.h>
#include <string>

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  @autoreleasepool {
    // Peekr downloads the framework to Application Support (NOT the app bundle),
    // so load it from --framework-dir-path, which CEF passes to every subprocess.
    // Fall back to the bundle-relative loader if the arg is absent.
    std::string fw;
    const std::string key = "--framework-dir-path=";
    for (int i = 1; i < argc; ++i) {
      std::string a = argv[i];
      if (a.rfind(key, 0) == 0) { fw = a.substr(key.size()); break; }
    }
    if (!fw.empty()) {
      if (!cef_load_library((fw + "/Chromium Embedded Framework").c_str())) return 1;
    } else {
      CefScopedLibraryLoader library_loader;
      if (!library_loader.LoadInHelper()) return 1;
    }

    CefMainArgs main_args(argc, argv);
    // A plain renderer/GPU/etc. helper needs no CefApp; CefExecuteProcess blocks
    // until the subprocess exits and returns its code.
    return CefExecuteProcess(main_args, nullptr, nullptr);
  }
}
