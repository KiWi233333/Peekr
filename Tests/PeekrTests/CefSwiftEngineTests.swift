import AppKit
import CefKit
import XCTest
@testable import Peekr

@MainActor
final class CefSwiftEngineTests: XCTestCase {
    private func makeEngine(url: URL? = URL(string: "https://example.com")) -> CefSwiftEngine {
        let app = WebApp(title: "Example", urlString: url?.absoluteString ?? "")
        return CefSwiftEngineFactory().makeEngine(for: app) as! CefSwiftEngine
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
            engine.routeWindowOpen(CefWindowOpenRequest(targetURL: url, disposition: .newPopup)),
            .handled
        )
        XCTAssertEqual(opened.map(\.url), [url, url, url])
        XCTAssertEqual(opened.map(\.foreground), [false, true, true])

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
}
