# Chrome-codec CEF runtime

Peekr remains a native Swift/AppKit/SwiftUI application. Its web content runs in
CEF helper processes; Electron and Node.js are not part of the application.

Here, “Electron-equivalent Chromium” means Blink/V8, Chromium networking and
storage, the multi-process renderer/GPU model, DevTools plumbing, downloads,
file selection, WebRTC/media capture, and Chrome-branded H.264/AAC decoding.
It does not mean Google Chrome Sync, the Chrome Web Store, bundled Widevine, or
closed Google services. Electron also supports only a subset of Chrome extension
APIs; those browser-product features are a separate integration and licensing
problem from embedding the Chromium engine.

The public CEF binary distribution intentionally omits patented/proprietary
codec support. To match Electron's Chromium media capability, Peekr builds the
exact CEF revision required by CefSwift with these GN arguments:

```text
is_official_build=true
proprietary_codecs=true
ffmpeg_branding=Chrome
use_thin_lto=false
symbol_level=0
```

## Build the macOS ARM64 artifact

The source build needs Xcode, an Apple Silicon Mac, at least 32 GiB RAM, and at
least 200 GiB free disk space. It is incremental and may take several hours.

```bash
PEEKR_CEF_BUILD_ROOT=/path/without/spaces/PeekrCEF \
  ./scripts/build-cef-chrome-codecs.sh
```

The script pins CEF `148.0.10+g7ee53f5+chromium-148.0.7778.218` at commit
`7ee53f518427a047f3c385446e3f92797e6b8cae`, verifies the pinned upstream
`automate-git.py`, and writes the minimal archive to `.cef/artifacts/`.

## Pin and consume the artifact

Add a project-root `CEF_VERSION.json` using the produced name, byte size, SHA-1,
and SHA-256. The `platforms.macosarm64.minimal` object accepts two Peekr fields
in addition to CefSwift's manifest schema:

```json
{
  "name": "cef_binary_<version>_macosarm64_chrome_codecs_minimal.tar.bz2",
  "sha1": "<40 hex characters>",
  "sha256": "<64 hex characters>",
  "size": 123,
  "source": "https://immutable-artifact-location/example.tar.bz2"
}
```

`scripts/prepare-cef.sh` accepts a local file (`PEEKR_CEF_ARTIFACT`), a local
directory (`PEEKR_CEF_ARTIFACT_DIR`), an exact URL
(`PEEKR_CEF_ARTIFACT_URL`), or a base URL (`PEEKR_CEF_BASE_URL`). It validates
size, SHA-1, and SHA-256 before CefSwift extracts the distribution. The normal
`scripts/bundle.sh` path performs this automatically.

For a deterministic runtime check, build a debug app and run:

```bash
./scripts/bundle.sh debug
./scripts/smoke-cef-media.sh build/Peekr.app
./scripts/smoke-cef-capabilities.sh build/Peekr.app
./scripts/smoke-cef-permissions.sh build/Peekr.app
```

The smoke test creates an H.264 Baseline + AAC MP4, launches a real isolated
Peekr/CEF profile, requires both a positive `canPlayType` result and an actual
`playing` event, then removes its temporary data. It never reads or writes the
user's normal Peekr profile.

The capability smoke also exercises a native CEF mouse event and macOS file
chooser, a real download, persistent storage across a full app restart,
Service Worker/Cache Storage/IndexedDB, WebAssembly, Web Worker, WebGL2,
WebGPU, WebRTC, media-capture APIs and the Chrome 148 user agent. The permission
smoke sends real user-media and display-media requests through Peekr's native
Swift permission delegate and takes a debug-only explicit deny path. Normal
Debug launches and all Release builds still require the user to answer the
native prompt.

Publishing or distributing H.264/AAC-capable binaries can create patent and
codec-licensing obligations. The build flags provide capability; they do not
grant distribution rights.
