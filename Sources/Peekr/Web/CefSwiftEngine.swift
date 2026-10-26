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
    private var measuredAudio: WebAudioActivity = .unknown
    private var isClosed = false
    #if DEBUG
    private var didRunInputSmoke = false
    private var completedSmokeDownloads: Set<UInt32> = []
    #endif

    var hostView: NSView { host }
    private(set) var navState: NavState
    /// CefSwift 0.1.0 exposes no audible-media signal, so the page reports it
    /// through a console probe. Until the probe answers, an unmuted page stays
    /// `.unknown` and is protected from automatic hibernation; an explicitly
    /// muted page is known to be silent regardless of the probe.
    var activity: WebActivitySnapshot {
        WebActivitySnapshot(audio: isAudioMuted ? .silent : measuredAudio)
    }
    var onNavStateChange: ((NavState) -> Void)?
    var onDownloadChange: ((WebDownload) -> Void)?
    var onFindResult: ((FindResult) -> Void)?
    var onAudioActivityChange: ((WebAudioActivity) -> Void)?

    /// The page asked for a new tab (⌘-click, middle-click, target=_blank,
    /// window.open). The flag is the foreground/background intent Chromium
    /// computed from the click. Set by the factory at creation.
    var onOpenNewTab: ((URL, Bool) -> Void)?
    /// Live string table for context-menu labels.
    var strings: () -> Localized = { Localized(isChinese: false) }
    /// Whether permission prompts may offer to remember the decision.
    var allowsPermissionMemory: () -> Bool = { true }
    /// Whether script-initiated popups without a user gesture are blocked.
    var blocksPopups: () -> Bool = { true }
    var onBlockedPopup: ((URL?) -> Void)?
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

    func pauseDownload(_ id: UInt32) {
        downloadCallbacks[id]?.pause()
    }

    func resumeDownload(_ id: UInt32) {
        downloadCallbacks[id]?.resume()
    }

    func find(_ text: String, forward: Bool, matchCase: Bool) {
        browser?.find(text, forward: forward, matchCase: matchCase)
    }

    func stopFinding() { browser?.stopFinding() }

    func toggleDevTools() {
        browser?.toggleDevTools()
    }

    func viewSource() {
        guard let sourceURL = Self.viewSourceURL(for: navState.url ?? browser?.url) else { return }
        onOpenNewTab?(sourceURL, true)
    }

    static func viewSourceURL(for url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return URL(string: "view-source:" + url.absoluteString)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        browser?.delegate = nil
        browser?.close(force: true)
        // CEF hosts a windowed browser inside an app-owned view/window. Its
        // default `do_close` handling sends a close notification to that hosting
        // NSWindow — Peekr's slide panel, which deliberately stays alive — so the
        // browser never finishes tearing down and `on_before_close` never fires.
        // The browser then stays registered with `CefRuntime`, and any quit that
        // waits for the registry to empty hangs forever. Removing the browser's
        // native view from the hierarchy completes the close: CEF destroys the
        // browser, fires `on_before_close`, and unregisters it from the runtime.
        browser?.nativeView?.removeFromSuperview()
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

    static func findResult(from result: CefFindResult) -> FindResult {
        FindResult(
            matches: result.matches,
            activeMatchOrdinal: result.activeMatchOrdinal,
            finalUpdate: result.finalUpdate
        )
    }

    private static let audioConsolePrefix = "__PEEKR_AUDIO__:"

    static func audioActivity(fromConsoleMessage message: String) -> WebAudioActivity? {
        guard message.hasPrefix(Self.audioConsolePrefix) else { return nil }
        switch message.dropFirst(Self.audioConsolePrefix.count) {
        case "1": return .audible
        case "0": return .silent
        default: return nil
        }
    }

    private static let audioProbeScript = """
    (function() {
        if (window.__peekrAudioHook) return;
        window.__peekrAudioHook = true;
        var last = null;
        function isAudible() {
            var media = document.querySelectorAll('audio,video');
            for (var i = 0; i < media.length; i++) {
                var el = media[i];
                if (!el.paused && !el.ended && el.readyState > 2 && !el.muted && el.volume > 0) {
                    return true;
                }
            }
            return false;
        }
        function report(force) {
            var value = isAudible() ? 1 : 0;
            if (!force && value === last) return;
            last = value;
            console.log('__PEEKR_AUDIO__:' + value);
        }
        ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'].forEach(function(name) {
            document.addEventListener(name, function() { setTimeout(report, 0); }, true);
        });
        report(true);
        setInterval(report, 2000);
    })();
    """

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
        CefPermissionPrompt.decide(
            request,
            strings: strings(),
            canRemember: allowsPermissionMemory()
        )
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
        if isLoading {
            measuredAudio = .unknown
            onAudioActivityChange?(.unknown)
        } else {
            browser.executeJavaScript(Self.audioProbeScript)
        }
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

    func browser(_ browser: CefBrowser, didUpdateFindResult result: CefFindResult) {
        onFindResult?(Self.findResult(from: result))
    }

    func browser(
        _ browser: CefBrowser,
        didReceiveConsoleMessage message: String,
        level: CefLogSeverity,
        source: String,
        line: Int
    ) {
        if message.hasPrefix(Self.audioConsolePrefix) {
            guard let activity = Self.audioActivity(fromConsoleMessage: message) else { return }
            measuredAudio = activity
            onAudioActivityChange?(activity)
            return
        }
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

    func browser(_ browser: CefBrowser, didEncounterCertificateError url: URL?, errorCode: Int) -> Bool {
        confirmCertificateError(url: url, errorCode: errorCode)
    }

    private func clearLoadError() {
        updateNavState {
            $0.loadError = nil
            $0.rendererFailure = nil
        }
    }

    private func confirmCertificateError(url: URL?, errorCode: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your connection is not private"
        let target = url?.host ?? url?.absoluteString ?? "this site"
        alert.informativeText = """
            The certificate for \(target) is not trusted (error \(errorCode)). \
            Continuing may expose your data to an attacker.
            """
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue")
        alert.buttons[1].hasDestructiveAction = true
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
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
        let isPopup = request.disposition == .newPopup || request.disposition == .newWindow
        if isPopup, !request.userGesture, blocksPopups() {
            onBlockedPopup?(url)
            return .deny
        }
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

    /// Custom command IDs inside CEF's user range (26500...28500).
    enum ContextMenuID {
        static let inspect = CefMenuModel.userCommandIDFirst
        static let openLinkInNewTab = inspect + 1
        static let copyLinkAddress = inspect + 2
        static let openImageInNewTab = inspect + 3
        static let copyImageAddress = inspect + 4
        static let searchSelection = inspect + 5
        static let openLinkInNewBackgroundTab = inspect + 6
        static let viewSource = inspect + 7
        static let copyImage = inspect + 8
        static let saveImage = inspect + 9
        static let copySelection = inspect + 10
        static let print = inspect + 11
        static let back = inspect + 12
        static let forward = inspect + 13
        static let saveLink = inspect + 14
        static let openMediaInNewTab = inspect + 15
        static let saveMedia = inspect + 16
        static let copyMediaAddress = inspect + 17
    }

    func browser(_ browser: CefBrowser, configureContextMenu menu: CefMenuModel, params: CefContextMenuParams) {
        // Editable nodes keep CEF's default menu (spellcheck, undo, paste…).
        guard !params.isEditable else { return }
        menu.clear()
        let strings = strings()
        var sections: [[(commandID: Int, title: String)]] = []

        if params.linkURL != nil {
            sections.append([
                (ContextMenuID.openLinkInNewTab, strings.openLinkInNewTab),
                (ContextMenuID.openLinkInNewBackgroundTab, strings.openLinkInNewBackgroundTab),
                (ContextMenuID.saveLink, strings.saveLinkAs),
                (ContextMenuID.copyLinkAddress, strings.copyLinkAddress),
            ])
        }
        if params.sourceURL != nil {
            switch params.mediaType {
            case .image:
                sections.append([
                    (ContextMenuID.openImageInNewTab, strings.openImageInNewTab),
                    (ContextMenuID.saveImage, strings.saveImageAs),
                    (ContextMenuID.copyImage, strings.copyImage),
                    (ContextMenuID.copyImageAddress, strings.copyImageAddress),
                ])
            case .video:
                sections.append([
                    (ContextMenuID.openMediaInNewTab, strings.openVideoInNewTab),
                    (ContextMenuID.saveMedia, strings.saveVideoAs),
                    (ContextMenuID.copyMediaAddress, strings.copyVideoAddress),
                ])
            case .audio:
                sections.append([
                    (ContextMenuID.openMediaInNewTab, strings.openAudioInNewTab),
                    (ContextMenuID.saveMedia, strings.saveAudioAs),
                    (ContextMenuID.copyMediaAddress, strings.copyAudioAddress),
                ])
            default:
                break
            }
        }

        let selection = params.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            let clipped = selection.count > 50 ? String(selection.prefix(50)) + "…" : selection
            sections.append([
                (ContextMenuID.copySelection, strings.copy),
                (ContextMenuID.searchSelection, strings.searchSelection(searchEngine(), for: clipped)),
            ])
        }
        if params.linkURL == nil {
            sections.append([
                (ContextMenuID.back, strings.back),
                (ContextMenuID.forward, strings.forward),
                (CefContextMenuCommand.reload.rawValue, strings.reload),
            ])
        }
        sections.append([(ContextMenuID.print, strings.printPage)])
        var tools = [(ContextMenuID.inspect, strings.inspect)]
        if selection.isEmpty { tools.insert((ContextMenuID.viewSource, strings.viewSource), at: 0) }
        sections.append(tools)

        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addSeparator() }
            for item in section {
                menu.addItem(commandID: item.commandID, title: item.title)
            }
        }
        menu.setEnabled(commandID: ContextMenuID.back, enabled: browser.canGoBack)
        menu.setEnabled(commandID: ContextMenuID.forward, enabled: browser.canGoForward)
    }

    func browser(_ browser: CefBrowser, contextMenuCommand commandID: Int, params: CefContextMenuParams) -> Bool {
        handleContextMenuCommand(commandID, params: params, browser: browser)
    }

    func handleContextMenuCommand(
        _ commandID: Int,
        params: CefContextMenuParams,
        browser: CefBrowser?
    ) -> Bool {
        switch commandID {
        case ContextMenuID.inspect:
            browser?.showDevTools()
        case ContextMenuID.openLinkInNewTab:
            guard let url = params.linkURL else { return false }
            onOpenNewTab?(url, true)
        case ContextMenuID.openLinkInNewBackgroundTab:
            guard let url = params.linkURL else { return false }
            onOpenNewTab?(url, false)
        case ContextMenuID.saveLink:
            guard let url = params.linkURL else { return false }
            browser?.startDownload(url)
        case ContextMenuID.copyLinkAddress:
            guard let url = params.linkURL else { return false }
            Self.copyToPasteboard(url.absoluteString)
        case ContextMenuID.openImageInNewTab, ContextMenuID.openMediaInNewTab:
            guard let url = params.sourceURL else { return false }
            onOpenNewTab?(url, true)
        case ContextMenuID.saveImage, ContextMenuID.saveMedia:
            guard let url = params.sourceURL else { return false }
            browser?.startDownload(url)
        case ContextMenuID.copyImage:
            guard let url = params.sourceURL else { return false }
            browser?.downloadImage(url) { data in
                guard let data else { return }
                Self.copyToPasteboard(data)
            }
        case ContextMenuID.copyImageAddress, ContextMenuID.copyMediaAddress:
            guard let url = params.sourceURL else { return false }
            Self.copyToPasteboard(url.absoluteString)
        case ContextMenuID.copySelection:
            browser?.copySelection()
        case ContextMenuID.searchSelection:
            let query = params.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let url = searchEngine().searchURL(for: query) else { return false }
            onOpenNewTab?(url, true)
        case ContextMenuID.back:
            goBack()
        case ContextMenuID.forward:
            goForward()
        case ContextMenuID.print:
            browser?.print()
        case ContextMenuID.viewSource:
            viewSource()
        default:
            return false
        }
        return true
    }

    @discardableResult
    static func copyToPasteboard(_ string: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }

    @discardableResult
    static func copyToPasteboard(_ pngData: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(pngData, forType: .png)
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
/// filesystem-safe storage keys. Incognito Profiles share one in-memory
/// request context that is discarded with the process.
@MainActor
final class CefSwiftEngineFactory: WebEngineFactory {
    private var profiles: [BrowserProfile.ID: CefProfile] = [:]
    private var incognitoProfile: CefProfile?

    /// Routes a page's new-tab request into Peekr's tab model. Wired by the
    /// composition root once the `WebViewManager` exists.
    var onOpenNewTab: ((URL, Bool) -> Void)?
    var strings: () -> Localized = { Localized(isChinese: false) }
    var allowsPermissionMemory: () -> Bool = { true }
    var blocksPopups: () -> Bool = { true }
    var searchEngine: () -> SearchEngine = { .google }

    init(
        onOpenNewTab: ((URL, Bool) -> Void)? = nil,
        strings: @escaping () -> Localized = { Localized(isChinese: false) },
        allowsPermissionMemory: @escaping () -> Bool = { true },
        blocksPopups: @escaping () -> Bool = { true },
        searchEngine: @escaping () -> SearchEngine = { .google }
    ) {
        self.onOpenNewTab = onOpenNewTab
        self.strings = strings
        self.allowsPermissionMemory = allowsPermissionMemory
        self.blocksPopups = blocksPopups
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
        engine.allowsPermissionMemory = allowsPermissionMemory
        engine.blocksPopups = blocksPopups
        engine.searchEngine = searchEngine
        return engine
    }

    /// Clear cookies and/or the HTTP cache for every request context backing a
    /// live browser. The cached instances are used so CEF sees exactly the
    /// contexts the open pages use; the global context is added when no cached
    /// default profile exists and cleared at most once. Incognito profiles are
    /// skipped because their session data is ephemeral — clearing them would
    /// unexpectedly wipe the private space.
    func clearBrowsingData(cookies: Bool, cache: Bool, completion: @escaping () -> Void) {
        var targets: [CefProfile] = []
        var hasGlobal = false
        for profile in profiles.values where !profile.isIncognito {
            if profile.isGlobal {
                guard !hasGlobal else { continue }
                hasGlobal = true
            }
            targets.append(profile)
        }
        if !hasGlobal { targets.append(.default) }
        CefBrowsingData.clear(
            profiles: targets,
            cookies: cookies,
            cache: cache,
            completion: completion
        )
    }

    private func cefProfile(for profile: BrowserProfile) -> CefProfile {
        if profile.isIncognito {
            if let cached = incognitoProfile { return cached }
            let created = CefProfile.incognito()
            incognitoProfile = created
            return created
        }
        if let cached = profiles[profile.id] { return cached }
        let resolved = profile.isDefault
            ? CefProfile.default
            : CefProfile.persistent(name: profile.storageKey)
        profiles[profile.id] = resolved
        return resolved
    }
}
