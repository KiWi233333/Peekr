import AppKit
import CefKit

/// Native child view used by the CefSwift windowed/Alloy browser. Browser
/// creation is deferred until the view belongs to a window because CEF requires
/// a live parent NSView; removing and re-adding the host preserves the browser.
@MainActor
final class CefSwiftBrowserHostView: NSView {
    weak var engine: CefSwiftEngine?

    // Windowed CEF's native child view does not expose AppKit's standard
    // editing responder actions. Keep them on the parent host so the Edit
    // menu can walk the responder chain just like a normal Chrome window.
    @objc func copy(_ sender: Any?) { engine?.copySelection() }
    @objc func cut(_ sender: Any?) { engine?.cutSelection() }
    @objc func paste(_ sender: Any?) { engine?.paste() }
    @objc func pasteAsPlainText(_ sender: Any?) { engine?.pasteAsPlainText() }
    @objc func delete(_ sender: Any?) { engine?.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { engine?.selectAll() }
    @objc func undo(_ sender: Any?) { engine?.undo() }
    @objc func redo(_ sender: Any?) { engine?.redo() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            engine?.attachBrowserIfNeeded()
        }
    }

    /// Two-finger trackpad swipe = history navigation, like Chrome. CEF's
    /// Alloy native view has no history-swipe handler of its own (that lives in
    /// Chromium's Chrome UI layer, which CEF doesn't ship), so an unconsumed
    /// swipe bubbles up the responder chain to this host. No `.swipe` event
    /// monitor is installed as a fallback: if the event arrives here it works,
    /// and a monitor would double-navigate whenever both paths fire.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            engine?.goBack()
        } else if event.deltaX < 0 {
            engine?.goForward()
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
    private var downloadNames: [UInt32: String] = [:]
    private var downloadCallbacks: [UInt32: CefDownloadItemCallback] = [:]
    private var requestedAudioMuted: Bool
    private var isClosed = false
    #if DEBUG
    private var didRunInputSmoke = false
    private var completedSmokeDownloads: Set<UInt32> = []
    #endif

    var hostView: NSView { host }
    private(set) var navState: NavState
    /// CefSwift 0.1.0 does not expose a reliable audible-media signal. Keep
    /// this unknown until the adapter gains one; lifecycle policy then fails
    /// closed instead of stopping background playback.
    var activity: WebActivitySnapshot { WebActivitySnapshot(audio: .unknown) }
    var onNavStateChange: ((NavState) -> Void)?
    var onDownloadChange: ((WebDownload) -> Void)?

    /// The page asked for a new tab (⌘-click, middle-click, target=_blank,
    /// window.open). The flag is the foreground/background intent Chromium
    /// computed from the click. Set by the factory at creation.
    var onOpenNewTab: ((URL, Bool) -> Void)?
    /// Live string table for context-menu labels.
    var strings: () -> Localized = { Localized(isChinese: false) }
    /// Live search engine for the selection-search menu item.
    var searchEngine: () -> SearchEngine = { .google }

    init(url: URL?, profile: CefProfile, isAudioMuted: Bool = false) {
        self.profile = profile
        pendingURL = url
        requestedAudioMuted = isAudioMuted
        var initialState = NavState()
        initialState.url = url
        navState = initialState
        host.engine = self
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        clearLoadError()
        pendingURL = url
        browser?.load(url)
    }

    func goBack() { clearLoadError(); browser?.goBack() }
    func goForward() { clearLoadError(); browser?.goForward() }
    func reload() { clearLoadError(); browser?.reload() }
    func reload(ignoreCache: Bool) { clearLoadError(); browser?.reload(ignoreCache: ignoreCache) }
    func stopLoading() { browser?.stopLoading() }

    func zoomIn() { browser?.zoomLevel += 1 }
    func zoomOut() { browser?.zoomLevel -= 1 }
    func zoomReset() { browser?.zoomLevel = 0 }
    func setZoomLevel(_ level: Double) { browser?.zoomLevel = level }

    var zoomLevel: Double { browser?.zoomLevel ?? 0 }

    var isAudioMuted: Bool {
        get { browser?.isAudioMuted ?? requestedAudioMuted }
        set {
            requestedAudioMuted = newValue
            browser?.isAudioMuted = newValue
        }
    }

    func cancelDownload(_ id: UInt32) {
        downloadCallbacks[id]?.cancel()
    }

    func find(_ text: String, forward: Bool, matchCase: Bool) {
        browser?.find(text, forward: forward, matchCase: matchCase)
    }

    /// CefSwift 0.1.0 doesn't wrap `cef_browser_host_t.stop_finding`; an empty
    /// search ends CEF's find session and clears its highlights.
    func stopFinding() { browser?.find("", forward: true, matchCase: false) }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        browser?.delegate = nil
        browser?.close(force: true)
        browser = nil
        pendingURL = nil
        faviconURLs = []
        downloadNames.removeAll()
        downloadCallbacks.removeAll()
    }

    func iconLinkURLs() async -> [URL] { faviconURLs }

    /// One viewport frame from this exact CEF browser, independent of the
    /// optional remote Agent/CDP port and AppKit's native-child view snapshot.
    func captureViewport() async -> Data? {
        guard !isClosed, let browser else { return nil }
        return await withCheckedContinuation { continuation in
            browser.captureViewport { payload in continuation.resume(returning: payload) }
        }
    }

    // MARK: Editing responder actions

    func copySelection() { browser?.copySelection() }
    func cutSelection() { browser?.cutSelection() }
    func paste() { browser?.paste() }
    func pasteAsPlainText() { browser?.pasteAndMatchStyle() }
    func deleteSelection() { browser?.deleteSelection() }
    func selectAll() { browser?.selectAll() }
    func undo() { browser?.undo() }
    func redo() { browser?.redo() }

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
        browser?.isAudioMuted = requestedAudioMuted
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
            if loading {
                $0.loadError = nil
                $0.rendererFailure = nil
            }
            if !loading { $0.progress = 1 }
        }
    }

    func applyProgress(_ progress: Double) {
        updateNavState { $0.progress = min(max(progress, 0), 1) }
    }

    func applyFailure(
        code: Int,
        errorText: String,
        failedURL: String,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        let url = URL(string: failedURL) ?? navState.url
        let failure = WebLoadFailure(code: code, message: errorText, url: url)
        updateNavState {
            $0.isLoading = false
            $0.progress = 1
            $0.canGoBack = canGoBack
            $0.canGoForward = canGoForward
            $0.url = url
            $0.loadError = failure
            $0.rendererFailure = nil
        }
    }

    func applyRendererFailure(reason: String, errorCode: Int) {
        updateNavState {
            $0.isLoading = false
            $0.progress = 1
            $0.rendererFailure = WebRendererFailure(reason: reason, code: errorCode)
            $0.loadError = nil
        }
    }

    static func isCanceledNavigationError(_ code: Int) -> Bool { code == -3 }

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
        let safeName = (suggestedName as NSString).lastPathComponent
        downloadNames[download.id] = safeName.isEmpty ? "download" : safeName
        onDownloadChange?(webDownload(from: download))
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["PEEKR_SMOKE_DOWNLOAD_DIR"] {
            let name = downloadNames[download.id] ?? "download"
            return .allow(destination: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        #endif
        return .allow(destination: nil)
    }

    func browser(_ browser: CefBrowser, downloadDidProgress download: CefDownload) {
        onDownloadChange?(webDownload(from: download))
        if download.isComplete || download.isCanceled || download.isInterrupted {
            downloadNames.removeValue(forKey: download.id)
            downloadCallbacks.removeValue(forKey: download.id)
        }
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PEEKR_SMOKE_DOWNLOAD_DIR"] != nil,
              (download.isComplete || download.isCanceled || download.isInterrupted),
              completedSmokeDownloads.insert(download.id).inserted else { return }
        let state = download.isComplete ? "PASS" : "FAIL"
        recordSmokeMessage("__PEEKR_CEF_SMOKE__:DOWNLOAD:\(state)", fileName: "cef-smoke.log")
        #endif
    }

    func browser(
        _ browser: CefBrowser,
        downloadDidUpdate download: CefDownload,
        callback: CefDownloadItemCallback
    ) {
        if !download.isComplete && !download.isCanceled && !download.isInterrupted {
            downloadCallbacks[download.id] = callback
        }
        self.browser(browser, downloadDidProgress: download)
    }

    private func webDownload(from download: CefDownload) -> WebDownload {
        WebDownload(
            id: download.id,
            url: download.url,
            fileName: downloadNames[download.id] ?? download.fullPath?.lastPathComponent ?? "download",
            receivedBytes: download.receivedBytes,
            totalBytes: download.totalBytes,
            state: download.isComplete
                ? .completed
                : download.isCanceled
                    ? .canceled
                    : download.isInterrupted ? .failed : .downloading,
            location: download.fullPath
        )
    }

    func browser(
        _ browser: CefBrowser,
        didFailLoad code: Int,
        errorText: String,
        failedURL: String
    ) {
        // CEF reports ERR_ABORTED when a load is superseded or stopped. Chrome
        // does not present that as a failed page.
        guard !Self.isCanceledNavigationError(code) else {
            applyLoading(false, canGoBack: browser.canGoBack, canGoForward: browser.canGoForward)
            return
        }
        applyFailure(
            code: code,
            errorText: errorText,
            failedURL: failedURL,
            canGoBack: browser.canGoBack,
            canGoForward: browser.canGoForward
        )
    }

    func browser(
        _ browser: CefBrowser,
        renderProcessDidTerminate reason: CefTerminationReason,
        errorCode: Int
    ) {
        applyRendererFailure(reason: String(describing: reason), errorCode: errorCode)
    }

    private func clearLoadError() {
        updateNavState {
            $0.loadError = nil
            $0.rendererFailure = nil
        }
    }

    /// ⌘-click / middle-click / target=_blank / window.open all arrive here.
    /// Peekr has no secondary windows, so every new-content request becomes a
    /// tab; Chromium's disposition only decides whether that tab takes focus.
    /// This replaces the legacy `requestsPopupFor` bridge, whose
    /// `openInSameBrowser` answer forced every link into the current tab.
    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        routeWindowOpen(request)
    }

    func routeWindowOpen(_ request: CefWindowOpenRequest) -> CefWindowOpenAction {
        guard let url = request.targetURL else { return .deny }
        switch request.disposition {
        case .newBackgroundTab:
            onOpenNewTab?(url, false)
            return .handled
        case .newForegroundTab, .newPopup, .newWindow:
            onOpenNewTab?(url, true)
            return .handled
        case .ignoreAction, .saveToDisk, .offTheRecord:
            return .deny
        default:
            return .openInCurrentBrowser
        }
    }

    // MARK: Context menu

    /// Custom command IDs inside CEF's user range (26500...28500). Built-in
    /// commands (reload) are executed by CEF itself; these need a handler in
    /// `contextMenuCommand`.
    private enum ContextMenuID {
        static let inspect = CefMenuModel.userCommandIDFirst
        static let openLinkInNewTab = inspect + 1
        static let copyLinkAddress = inspect + 2
        static let openImageInNewTab = inspect + 3
        static let copyImageAddress = inspect + 4
        static let searchSelection = inspect + 5
    }

    func browser(_ browser: CefBrowser, configureContextMenu menu: CefMenuModel, params: CefContextMenuParams) {
        // Editable nodes keep CEF's default menu (spellcheck, undo, paste…).
        guard !params.isEditable else { return }
        let strings = strings()

        var index = 0
        func insert(_ commandID: Int, _ title: String) {
            menu.insertItem(at: index, commandID: commandID, title: title)
            index += 1
        }

        if params.linkURL != nil {
            insert(ContextMenuID.openLinkInNewTab, strings.openLinkInNewTab)
            insert(ContextMenuID.copyLinkAddress, strings.copyLinkAddress)
            menu.insertSeparator(at: index); index += 1
        }
        if params.mediaType == .image, params.sourceURL != nil {
            insert(ContextMenuID.openImageInNewTab, strings.openImageInNewTab)
            insert(ContextMenuID.copyImageAddress, strings.copyImageAddress)
            menu.insertSeparator(at: index); index += 1
        }
        let selection = params.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            let clipped = selection.count > 50 ? String(selection.prefix(50)) + "…" : selection
            insert(ContextMenuID.searchSelection, strings.searchSelection(searchEngine(), for: clipped))
            menu.insertSeparator(at: index); index += 1
        }

        // Chrome's tail group: Reload runs as CEF's built-in command, Inspect
        // is ours. Always present for non-editable targets.
        menu.addSeparator()
        menu.addItem(commandID: CefContextMenuCommand.reload.rawValue, title: strings.reload)
        menu.addItem(commandID: ContextMenuID.inspect, title: strings.inspect)
    }

    func browser(_ browser: CefBrowser, contextMenuCommand commandID: Int, params: CefContextMenuParams) -> Bool {
        switch commandID {
        case ContextMenuID.inspect:
            browser.showDevTools()
        case ContextMenuID.openLinkInNewTab:
            guard let url = params.linkURL else { return false }
            onOpenNewTab?(url, true)
        case ContextMenuID.copyLinkAddress:
            guard let url = params.linkURL else { return false }
            copyToPasteboard(url.absoluteString)
        case ContextMenuID.openImageInNewTab:
            guard let url = params.sourceURL else { return false }
            onOpenNewTab?(url, true)
        case ContextMenuID.copyImageAddress:
            guard let url = params.sourceURL else { return false }
            copyToPasteboard(url.absoluteString)
        case ContextMenuID.searchSelection:
            let query = params.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let url = searchEngine().searchURL(for: query) else { return false }
            onOpenNewTab?(url, true)
        default:
            return false
        }
        return true
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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

/// Resolves one native CEF request context per domain Profile. The default
/// Profile deliberately reuses CEF's global context so existing
/// `Chromium/Default` data remains in place; named Profiles use immutable,
/// filesystem-safe storage keys.
@MainActor
final class CefSwiftEngineFactory: WebEngineFactory {
    private var profiles: [BrowserProfile.ID: CefProfile] = [:]

    /// Routes a page's new-tab request into Peekr's tab model. Wired by the
    /// composition root once the `WebViewManager` exists.
    var onOpenNewTab: ((URL, Bool) -> Void)?
    var strings: () -> Localized = { Localized(isChinese: false) }
    var searchEngine: () -> SearchEngine = { .google }

    init(
        onOpenNewTab: ((URL, Bool) -> Void)? = nil,
        strings: @escaping () -> Localized = { Localized(isChinese: false) },
        searchEngine: @escaping () -> SearchEngine = { .google }
    ) {
        self.onOpenNewTab = onOpenNewTab
        self.strings = strings
        self.searchEngine = searchEngine
    }

    func makeEngine(for app: WebApp, profile: BrowserProfile) -> WebEngine {
        let engine = CefSwiftEngine(
            url: app.url,
            profile: cefProfile(for: profile),
            isAudioMuted: app.isMuted
        )
        engine.onOpenNewTab = onOpenNewTab
        engine.strings = strings
        engine.searchEngine = searchEngine
        return engine
    }

    private func cefProfile(for profile: BrowserProfile) -> CefProfile {
        if let cached = profiles[profile.id] { return cached }
        let resolved = profile.isDefault
            ? CefProfile.default
            : CefProfile.persistent(name: profile.storageKey)
        profiles[profile.id] = resolved
        return resolved
    }
}
