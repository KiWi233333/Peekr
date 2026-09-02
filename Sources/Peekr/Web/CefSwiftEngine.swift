import AppKit
import CefKit

/// Native child view used by the CefSwift windowed/Alloy browser. Browser
/// creation is deferred until the view belongs to a window because CEF requires
/// a live parent NSView; removing and re-adding the host preserves the browser.
@MainActor
final class CefSwiftBrowserHostView: NSView {
    weak var engine: CefSwiftEngine?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            engine?.attachBrowserIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        engine?.resizeBrowserView()
    }
}

/// Peekr's `WebEngine` adapter over CefSwift's public `CefBrowser` API.
///
/// CefSwift owns framework loading, CEF initialization, the external message
/// pump, helper processes and shutdown. This adapter only owns one browser,
/// translates its delegate events into Peekr's `NavState`, and exposes the
/// native view expected by `WebContainer`.
@MainActor
final class CefSwiftEngine: WebEngine {
    private let host = CefSwiftBrowserHostView()
    private let profile: CefProfile
    private var browser: CefBrowser?
    private var pendingURL: URL?
    private var faviconURLs: [URL] = []
    private var isClosed = false
    #if DEBUG
    private var didRunInputSmoke = false
    private var completedSmokeDownloads: Set<UInt32> = []
    #endif

    var hostView: NSView { host }
    private(set) var navState: NavState
    var onNavStateChange: ((NavState) -> Void)?

    init(url: URL?, profile: CefProfile) {
        self.profile = profile
        pendingURL = url
        var initialState = NavState()
        initialState.url = url
        navState = initialState
        host.engine = self
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        pendingURL = url
        browser?.load(url)
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }
    func stopLoading() { browser?.stopLoading() }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        browser?.delegate = nil
        browser?.close(force: true)
        browser = nil
        pendingURL = nil
        faviconURLs = []
    }

    func iconLinkURLs() async -> [URL] { faviconURLs }

    /// Create the CEF browser exactly once, at the first point the native host
    /// is attached to a real window.
    func attachBrowserIfNeeded() {
        guard !isClosed, browser == nil, host.window != nil else { return }

        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        options.profile = profile
        let initialURL = pendingURL ?? navState.url ?? URL(string: "about:blank")!
        let created = CefBrowser.createBrowser(
            parentView: host,
            bounds: host.bounds,
            url: initialURL,
            options: options,
            delegate: self
        )
        guard created.id >= 0 else {
            FileHandle.standardError.write(
                Data("Peekr: CefSwift failed to create a Chromium browser.\n".utf8)
            )
            applyLoading(false, canGoBack: false, canGoForward: false)
            return
        }

        browser = created
        pendingURL = nil
        resizeBrowserView()
    }

    func resizeBrowserView() {
        guard let native = browser?.nativeView else { return }
        if native.superview !== host {
            native.removeFromSuperview()
            host.addSubview(native)
        }
        if native.frame != host.bounds {
            native.frame = host.bounds
        }
        native.autoresizingMask = [.width, .height]
    }

    // MARK: - State translation

    func applyTitle(_ title: String) {
        updateNavState { $0.title = title }
    }

    func applyURL(_ url: URL?) {
        updateNavState { $0.url = url }
    }

    func applyLoading(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        updateNavState {
            $0.isLoading = loading
            $0.canGoBack = canGoBack
            $0.canGoForward = canGoForward
            if !loading { $0.progress = 1 }
        }
    }

    func applyProgress(_ progress: Double) {
        updateNavState { $0.progress = min(max(progress, 0), 1) }
    }

    private func updateNavState(_ update: (inout NavState) -> Void) {
        var next = navState
        update(&next)
        guard next != navState else { return }
        navState = next
        onNavStateChange?(next)
    }

    #if DEBUG
    private func recordSmokeMessage(_ message: String, fileName: String) {
        let resultURL = AppPaths.supportDirectory.appendingPathComponent(fileName)
        let bytes = Data((message + "\n").utf8)
        if !FileManager.default.fileExists(atPath: resultURL.path) {
            FileManager.default.createFile(atPath: resultURL.path, contents: bytes)
        } else if let handle = try? FileHandle(forWritingTo: resultURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
            try? handle.close()
        }
    }
    #endif
}

extension CefSwiftEngine: CefBrowserDelegate {
    func browser(
        _ browser: CefBrowser,
        requestsPermission request: CefPermissionRequest
    ) -> CefPermissionDecision {
        CefPermissionPrompt.decide(request)
    }

    func browser(
        _ browser: CefBrowser,
        didReceiveAuthChallenge challenge: CefAuthChallenge,
        callback: CefAuthCallback
    ) -> Bool {
        CefHTTPAuthPrompt.present(challenge, callback: callback)
    }

    func browser(_ browser: CefBrowser, didChangeTitle title: String) {
        applyTitle(title)
    }

    func browser(_ browser: CefBrowser, didChangeURL url: URL?) {
        applyURL(url)
    }

    func browser(
        _ browser: CefBrowser,
        didChangeLoading isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        applyLoading(isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
        #if DEBUG
        if !isLoading,
           !didRunInputSmoke,
           ProcessInfo.processInfo.environment["PEEKR_SMOKE_CLICK"] == "1" {
            didRunInputSmoke = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                let point = CGPoint(x: 120, y: 120)
                browser.sendMouseMove(to: point, modifiers: 0)
                browser.sendMouseDown(at: point, button: .left, clickCount: 1, modifiers: 0)
                browser.sendMouseUp(at: point, button: .left, clickCount: 1, modifiers: 0)
                try? await Task.sleep(for: .milliseconds(700))
                if let panel = NSApp.windows.compactMap({ $0 as? NSOpenPanel }).first {
                    recordSmokeMessage(
                        "__PEEKR_CEF_SMOKE__:FILE_CHOOSER_NATIVE:PASS",
                        fileName: "cef-smoke.log"
                    )
                    panel.cancel(nil)
                } else {
                    recordSmokeMessage(
                        "__PEEKR_CEF_SMOKE__:FILE_CHOOSER_NATIVE:FAIL",
                        fileName: "cef-smoke.log"
                    )
                }
            }
        }
        #endif
    }

    func browser(_ browser: CefBrowser, didChangeProgress progress: Double) {
        applyProgress(progress)
    }

    func browser(_ browser: CefBrowser, didChangeFavicon urls: [URL]) {
        faviconURLs = urls
    }

    func browser(
        _ browser: CefBrowser,
        didReceiveConsoleMessage message: String,
        level: CefLogSeverity,
        source: String,
        line: Int
    ) {
        #if DEBUG
        if message.hasPrefix("__PEEKR_CODEC_SMOKE__") {
            recordSmokeMessage(message, fileName: "codec-smoke.log")
        } else if message.hasPrefix("__PEEKR_CEF_SMOKE__") {
            recordSmokeMessage(message, fileName: "cef-smoke.log")
        } else if message.hasPrefix("__PEEKR_PERMISSION_SMOKE__") {
            recordSmokeMessage(message, fileName: "permission-result.log")
        }
        #endif
    }

    func browser(
        _ browser: CefBrowser,
        decidePolicyForDownload download: CefDownload,
        suggestedName: String
    ) -> CefDownloadDecision {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["PEEKR_SMOKE_DOWNLOAD_DIR"] {
            let safeName = (suggestedName as NSString).lastPathComponent
            let name = safeName.isEmpty ? "download" : safeName
            return .allow(destination: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        #endif
        return .allow(destination: nil)
    }

    func browser(_ browser: CefBrowser, downloadDidProgress download: CefDownload) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PEEKR_SMOKE_DOWNLOAD_DIR"] != nil,
              (download.isComplete || download.isCanceled),
              completedSmokeDownloads.insert(download.id).inserted else { return }
        let state = download.isComplete ? "PASS" : "FAIL"
        recordSmokeMessage("__PEEKR_CEF_SMOKE__:DOWNLOAD:\(state)", fileName: "cef-smoke.log")
        #endif
    }

    func browser(
        _ browser: CefBrowser,
        didFailLoad code: Int,
        errorText: String,
        failedURL: String
    ) {
        applyLoading(false, canGoBack: browser.canGoBack, canGoForward: browser.canGoForward)
    }

    func browser(_ browser: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision {
        .openInSameBrowser
    }

    func browserDidClose(_ closedBrowser: CefBrowser) {
        if browser === closedBrowser {
            browser = nil
        }
        // A runtime-initiated close (including app termination) must not be
        // interpreted by a still-mounted host view as a request to recreate the
        // browser on its next layout/viewDidMoveToWindow callback.
        isClosed = true
        applyLoading(false, canGoBack: false, canGoForward: false)
    }
}

/// Every Chromium tab shares CefSwift's persistent global profile — this is the
/// chosen design, not a stopgap: agent and user pages inherit one another's
/// logins inside the one browser (the ego-lite model Peekr builds on). A
/// secondary constraint keeps it this way for now: CefSwift 0.1.0 places named
/// profiles two levels below CEF's root cache, while Chromium only accepts
/// profile directories that are direct children of that root, so per-space
/// profiles wait on the upstream layout fix.
@MainActor
struct CefSwiftEngineFactory: WebEngineFactory {
    func makeEngine(for app: WebApp) -> WebEngine {
        CefSwiftEngine(url: app.url, profile: .default)
    }
}
