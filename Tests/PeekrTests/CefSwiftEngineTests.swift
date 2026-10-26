import AppKit
import CefKit
import XCTest
@testable import Peekr

@MainActor
final class CefSwiftEngineTests: XCTestCase {
    private func makeEngine(url: URL? = URL(string: "https://example.com")) -> CefSwiftEngine {
        let app = WebApp(title: "Example", urlString: url?.absoluteString ?? "")
        return CefSwiftEngineFactory().makeEngine(
            for: app,
            profile: .defaultProfile
        ) as! CefSwiftEngine
    }

    func testFactoryBuildsNativeCefSwiftEngineWithoutCreatingBrowserEarly() {
        let url = URL(string: "https://example.com")!
        let engine = makeEngine(url: url)

        XCTAssertTrue(engine.hostView is CefSwiftBrowserHostView)
        XCTAssertEqual(engine.navState.url, url)
        XCTAssertNil(engine.hostView.window)
    }

    func testCefDelegateStateTranslationPublishesCompleteSnapshots() {
        let engine = makeEngine()
        var snapshots: [NavState] = []
        engine.onNavStateChange = { snapshots.append($0) }

        engine.applyTitle("Inbox")
        engine.applyURL(URL(string: "https://mail.example.com"))
        engine.applyProgress(0.4)
        engine.applyLoading(true, canGoBack: true, canGoForward: false)

        XCTAssertEqual(engine.navState.title, "Inbox")
        XCTAssertEqual(engine.navState.url, URL(string: "https://mail.example.com"))
        XCTAssertEqual(engine.navState.progress, 0.4)
        XCTAssertTrue(engine.navState.isLoading)
        XCTAssertTrue(engine.navState.canGoBack)
        XCTAssertEqual(snapshots.last, engine.navState)
    }

    func testSettledLoadCompletesProgress() {
        let engine = makeEngine()
        engine.applyProgress(0.55)
        engine.applyLoading(false, canGoBack: false, canGoForward: true)

        XCTAssertFalse(engine.navState.isLoading)
        XCTAssertEqual(engine.navState.progress, 1)
        XCTAssertTrue(engine.navState.canGoForward)
    }

    func testFailedLoadPublishesRecoveryStateAndLoadingClearsIt() {
        let engine = makeEngine()
        let failedURL = "https://missing.example/page"

        engine.applyFailure(
            code: -105,
            errorText: "ERR_NAME_NOT_RESOLVED",
            failedURL: failedURL,
            canGoBack: true,
            canGoForward: false
        )

        XCTAssertEqual(engine.navState.loadError?.code, -105)
        XCTAssertEqual(engine.navState.loadError?.message, "ERR_NAME_NOT_RESOLVED")
        XCTAssertEqual(engine.navState.loadError?.url?.absoluteString, failedURL)
        XCTAssertFalse(engine.navState.isLoading)
        XCTAssertTrue(engine.navState.canGoBack)

        engine.applyLoading(true, canGoBack: true, canGoForward: false)
        XCTAssertNil(engine.navState.loadError)
    }

    func testRendererTerminationPublishesRecoveryStateAndLoadingClearsIt() {
        let engine = makeEngine()

        engine.applyRendererFailure(reason: "crashed", errorCode: 139)

        XCTAssertEqual(engine.navState.rendererFailure?.reason, "crashed")
        XCTAssertEqual(engine.navState.rendererFailure?.code, 139)
        XCTAssertNil(engine.navState.loadError)

        engine.applyLoading(true, canGoBack: false, canGoForward: false)
        XCTAssertNil(engine.navState.rendererFailure)
    }

    func testCanceledNavigationErrorIsNotPresentedAsPageFailure() {
        XCTAssertTrue(CefSwiftEngine.isCanceledNavigationError(-3))
        XCTAssertFalse(CefSwiftEngine.isCanceledNavigationError(-105))
    }

    func testProgressIsClamped() {
        let engine = makeEngine()
        engine.applyProgress(2)
        XCTAssertEqual(engine.navState.progress, 1)
        engine.applyProgress(-1)
        XCTAssertEqual(engine.navState.progress, 0)
    }

    func testCloseIsIdempotentBeforeNativeBrowserCreation() {
        let engine = makeEngine()
        engine.close()
        engine.close()
        engine.load(URL(string: "https://ignored.example.com")!)

        XCTAssertEqual(engine.navState.url, URL(string: "https://example.com"))
    }

    func testWindowOpenRoutingFollowsChromiumDisposition() {
        let engine = makeEngine()
        var opened: [(url: URL, foreground: Bool)] = []
        engine.onOpenNewTab = { opened.append(($0, $1)) }
        let url = URL(string: "https://opened.example")!

        // ⌘-click / middle-click → background tab.
        XCTAssertEqual(
            engine.routeWindowOpen(CefWindowOpenRequest(targetURL: url, disposition: .newBackgroundTab)),
            .handled
        )
        // ⌘⇧-click → foreground tab; window.open popup → foreground tab.
        XCTAssertEqual(
            engine.routeWindowOpen(CefWindowOpenRequest(targetURL: url, disposition: .newForegroundTab)),
            .handled
        )
        XCTAssertEqual(
            engine.routeWindowOpen(CefWindowOpenRequest(
                targetURL: url,
                disposition: .newPopup,
                userGesture: true
            )),
            .handled
        )
        XCTAssertEqual(opened.map(\.url), [url, url, url])
        XCTAssertEqual(opened.map(\.foreground), [false, true, true])

        // Script-initiated popups without a user gesture are blocked.
        XCTAssertEqual(
            engine.routeWindowOpen(CefWindowOpenRequest(
                targetURL: url,
                disposition: .newPopup,
                userGesture: false
            )),
            .deny
        )
        XCTAssertEqual(opened.count, 3)

        // Plain clicks stay in the current browser; nothing escapes to a tab.
        XCTAssertEqual(
            engine.routeWindowOpen(CefWindowOpenRequest(targetURL: url, disposition: .currentTab)),
            .openInCurrentBrowser
        )
        XCTAssertEqual(
            engine.routeWindowOpen(CefWindowOpenRequest(targetURL: url, disposition: .saveToDisk)),
            .deny
        )
        XCTAssertEqual(engine.routeWindowOpen(CefWindowOpenRequest(targetURL: nil)), .deny)
        XCTAssertEqual(opened.count, 3)
    }

    func testFindResultMappingKeepsCountsAndDropsTheSessionIdentifier() {
        let mapped = CefSwiftEngine.findResult(
            from: CefFindResult(
                identifier: 12,
                matches: 7,
                activeMatchOrdinal: 3,
                finalUpdate: true
            )
        )

        XCTAssertEqual(
            mapped,
            FindResult(matches: 7, activeMatchOrdinal: 3, finalUpdate: true)
        )
    }

    func testViewSourceOpensForegroundTabOnlyForWebPages() {
        let engine = makeEngine()
        var opened: [(url: URL, foreground: Bool)] = []
        engine.onOpenNewTab = { opened.append(($0, $1)) }

        engine.viewSource()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.url.absoluteString, "view-source:https://example.com")
        XCTAssertEqual(opened.first?.foreground, true)
        XCTAssertEqual(engine.navState.url, URL(string: "https://example.com"))

        engine.applyURL(URL(string: "file:///tmp/page.html"))
        engine.viewSource()
        XCTAssertEqual(opened.count, 1)

        engine.applyURL(URL(string: "http://example.com/a?b=1"))
        engine.viewSource()
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened.last?.url.absoluteString, "view-source:http://example.com/a?b=1")
    }

    func testDownloadAndDevToolsControlsAreSafeBeforeBrowserCreation() {
        let engine = makeEngine()
        var downloads: [WebDownload] = []
        engine.onDownloadChange = { downloads.append($0) }

        engine.pauseDownload(7)
        engine.resumeDownload(7)
        engine.retryDownload(7)
        engine.cancelDownload(7)
        engine.toggleDevTools()

        XCTAssertTrue(downloads.isEmpty)
        XCTAssertEqual(engine.navState.url, URL(string: "https://example.com"))
    }

    func testContextMenuCommandsRouteTabsAndSelectionSearch() {
        let engine = makeEngine()
        var opened: [(url: URL, foreground: Bool)] = []
        engine.onOpenNewTab = { opened.append(($0, $1)) }
        let link = URL(string: "https://example.com/linked")!
        let image = URL(string: "https://example.com/image.png")!

        XCTAssertTrue(engine.handleContextMenuCommand(
            CefSwiftEngine.ContextMenuID.openLinkInNewBackgroundTab,
            params: CefContextMenuParams(linkURL: link),
            browser: nil
        ))
        XCTAssertTrue(engine.handleContextMenuCommand(
            CefSwiftEngine.ContextMenuID.openImageInNewTab,
            params: CefContextMenuParams(sourceURL: image, mediaType: .image),
            browser: nil
        ))
        XCTAssertTrue(engine.handleContextMenuCommand(
            CefSwiftEngine.ContextMenuID.searchSelection,
            params: CefContextMenuParams(selectionText: "  Peekr browser  "),
            browser: nil
        ))

        XCTAssertEqual(opened.map(\.url), [link, image, URL(string: "https://www.google.com/search?q=Peekr%20browser")!])
        XCTAssertEqual(opened.map(\.foreground), [false, true, true])
        XCTAssertFalse(engine.handleContextMenuCommand(
            CefSwiftEngine.ContextMenuID.copyImage,
            params: CefContextMenuParams(),
            browser: nil
        ))
    }

    func testContextMenuClipboardHelpersWriteTextAndRealPNGData() {
        let textBoard = NSPasteboard(name: NSPasteboard.Name("PeekrTests.text.\(UUID().uuidString)"))
        let imageBoard = NSPasteboard(name: NSPasteboard.Name("PeekrTests.image.\(UUID().uuidString)"))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        XCTAssertTrue(CefSwiftEngine.copyToPasteboard("https://example.com", to: textBoard))
        XCTAssertEqual(textBoard.string(forType: .string), "https://example.com")
        XCTAssertTrue(CefSwiftEngine.copyToPasteboard(png, to: imageBoard))
        XCTAssertEqual(imageBoard.data(forType: .png), png)
        XCTAssertNil(imageBoard.string(forType: .string))
    }

    func testContextMenuNativeActionsAreSafeBeforeBrowserCreation() {
        let engine = makeEngine()
        let params = CefContextMenuParams(
            linkURL: URL(string: "https://example.com/file.zip"),
            sourceURL: URL(string: "https://example.com/image.png"),
            selectionText: "selection",
            mediaType: .image
        )
        let commands = [
            CefSwiftEngine.ContextMenuID.inspect,
            CefSwiftEngine.ContextMenuID.saveLink,
            CefSwiftEngine.ContextMenuID.saveImage,
            CefSwiftEngine.ContextMenuID.copyImage,
            CefSwiftEngine.ContextMenuID.copySelection,
            CefSwiftEngine.ContextMenuID.back,
            CefSwiftEngine.ContextMenuID.forward,
            CefSwiftEngine.ContextMenuID.print,
        ]
        for command in commands {
            XCTAssertTrue(engine.handleContextMenuCommand(command, params: params, browser: nil))
        }
    }

    func testProtocolDefaultsLeaveUnsupportedCapabilitiesInert() {
        let engine = BareEngine()
        engine.onFindResult = { _ in XCTFail("default find callback must stay inert") }

        engine.find("term", forward: true, matchCase: true)
        engine.stopFinding()
        engine.toggleDevTools()
        engine.viewSource()
        engine.pauseDownload(1)
        engine.resumeDownload(1)
        engine.retryDownload(1)
        engine.cancelDownload(1)

        XCTAssertNil(engine.onFindResult)
    }
}

@MainActor
private final class BareEngine: WebEngine {
    let hostView = NSView()
    var navState = NavState()
    var onNavStateChange: ((NavState) -> Void)?
    var onDownloadChange: ((WebDownload) -> Void)?

    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func iconLinkURLs() async -> [URL] { [] }
}
