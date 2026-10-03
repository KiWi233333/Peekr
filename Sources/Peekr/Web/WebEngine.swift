import AppKit

/// A backend-neutral description of a failed main-frame navigation.
struct WebLoadFailure: Equatable {
    let code: Int
    let message: String
    let url: URL?

    var diagnostic: String {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Error \(code)" : detail
    }
}

/// A renderer-process termination is separate from a network/navigation error:
/// the browser target still exists, but its page needs a reload to recover.
struct WebRendererFailure: Equatable {
    let reason: String
    let code: Int
}

/// A snapshot of one page's navigation state, mirrored into `BrowserState`.
/// Engine-agnostic on purpose: backend-specific types never leak past this seam.
struct NavState: Equatable {
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var url: URL?
    var title = ""
    var loadError: WebLoadFailure?
    var rendererFailure: WebRendererFailure?
}

/// Backend-neutral snapshot of a browser download. The CEF-specific download
/// item never crosses this seam, so the panel can expose download state without
/// coupling the app model or UI to CEF.
enum WebDownloadState: Equatable {
    case downloading
    case completed
    case canceled
    case failed
}

struct WebDownload: Identifiable, Equatable {
    let id: UInt32
    var url: URL?
    var fileName: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var state: WebDownloadState
    var location: URL?

    var progress: Double? {
        guard totalBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }
}

/// One live web page for a dock app. The rendering backend lives entirely behind
/// this protocol, so `WebViewManager` and the whole panel/UI layer never touch
/// directly. The seam keeps the UI independent from CEF implementation details.
@MainActor
protocol WebEngine: AnyObject {
    /// The AppKit view `WebContainer` mounts into the panel.
    var hostView: NSView { get }
    /// Current navigation state; read on activation to seed the foreground UI.
    var navState: NavState { get }
    /// Nav-state callback. `WebViewManager` keeps it set on every engine — even
    /// background ones — so each tab's unread badge stays current; it mirrors to
    /// the shared `BrowserState` only for the engine whose id is foreground.
    var onNavStateChange: ((NavState) -> Void)? { get set }
    /// Download events emitted by the backend for the app-wide download center.
    var onDownloadChange: ((WebDownload) -> Void)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    /// ⌘⇧R hard reload, bypassing the cache.
    func reload(ignoreCache: Bool)
    func stopLoading()
    /// Page zoom (Chrome's ⌘=/⌘-/⌘0).
    var zoomLevel: Double { get }
    func zoomIn()
    func zoomOut()
    func zoomReset()
    /// Find-in-page session (⌘F).
    func find(_ text: String, forward: Bool, matchCase: Bool)
    func stopFinding()
    /// Mute this tab's page audio without muting macOS or other tabs.
    var isAudioMuted: Bool { get set }
    func cancelDownload(_ id: UInt32)
    /// Release backend resources immediately when a tab is discarded or the
    /// selected tab is discarded. CEF must explicitly close its browser before
    /// the runtime can terminate.
    func close()

    /// The page's declared favicon `<link>` URLs read from the *live* DOM (already
    /// resolved to absolute). Reading the rendered DOM — not a second HTML fetch —
    /// captures icons that SPAs inject via JS. Empty when none are declared.
    func iconLinkURLs() async -> [URL]
}

extension WebEngine {
    func close() {}
    var zoomLevel: Double { 0 }
    func reload(ignoreCache: Bool) { reload() }
    func zoomIn() {}
    func zoomOut() {}
    func zoomReset() {}
    func find(_ text: String, forward: Bool, matchCase: Bool) {}
    func stopFinding() {}
    var isAudioMuted: Bool {
        get { false }
        set {}
    }
    func cancelDownload(_ id: UInt32) {}
}

/// Builds a Chromium `WebEngine` per dock app. Keeping this small seam makes
/// lifecycle tests independent from the native CEF runtime.
@MainActor
protocol WebEngineFactory {
    func makeEngine(for app: WebApp) -> WebEngine
}
