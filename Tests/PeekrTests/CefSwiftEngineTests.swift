import AppKit
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
}
