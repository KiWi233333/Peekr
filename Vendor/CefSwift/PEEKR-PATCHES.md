# Peekr's CefSwift patch

This directory is CefSwift 0.1.0 at commit `2dca11e38e5cf12309bb867cb727362d7fb080e8` (MIT), with a narrow local patch:

- `Sources/CCef/include/CCef.h` imports the DevTools observer C API.
- `Sources/CefKit/CefBrowser+Screenshot.swift` exposes one-shot viewport capture through CEF's in-process DevTools protocol. It installs a per-request observer, releases it on result or timeout, and passes the raw result to the caller for decoding off the UI thread.

The vendored copy keeps the upstream package layout and CEF license files so SwiftPM's bundle plugin and redistribution remain reproducible. Compare it against the pinned commit before rebasing to a newer CefSwift release.
