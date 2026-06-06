import XCTest
import AppKit
@testable import Peekr

/// `CEFEngine` is the Swift-side Chromium engine: it maps a libcef-backed
/// `CEFBridge` onto Peekr's engine-agnostic `WebEngine`. The libcef/C++ wiring is
/// isolated behind `CEFBridge`, so the engine's own logic — forward nav calls,
/// mirror bridge state into `navState`, fire `onNavStateChange` — is tested here
/// with a fake bridge, no Chromium runtime required.
@MainActor
final class CEFEngineTests: XCTestCase {
    /// Stand-in for the future libcef shim: records calls and lets the test drive
    /// the nav-state callback.
    private final class FakeCEFBridge: CEFBridge {
        let view = NSView()
        var onNavState: ((NavState) -> Void)?
        var loaded: [URL] = []
        var backCount = 0, forwardCount = 0, reloadCount = 0, stopCount = 0
        func load(_ url: URL) { loaded.append(url) }
        func goBack() { backCount += 1 }
        func goForward() { forwardCount += 1 }
        func reload() { reloadCount += 1 }
        func stopLoading() { stopCount += 1 }
    }

    func testLoadsInitialURLOnInit() {
        let bridge = FakeCEFBridge()
        _ = CEFEngine(bridge: bridge, url: URL(string: "https://x.com")!)
        XCTAssertEqual(bridge.loaded, [URL(string: "https://x.com")!])
    }

    func testNilInitialURLLoadsNothing() {
        let bridge = FakeCEFBridge()
        _ = CEFEngine(bridge: bridge, url: nil)
        XCTAssertTrue(bridge.loaded.isEmpty)
    }

    func testNavMethodsForwardToBridge() {
        let bridge = FakeCEFBridge()
        let engine = CEFEngine(bridge: bridge, url: nil)
        engine.load(URL(string: "https://a.com")!)
        engine.goBack(); engine.goForward(); engine.reload(); engine.stopLoading()
        XCTAssertEqual(bridge.loaded, [URL(string: "https://a.com")!])
        XCTAssertEqual(bridge.backCount, 1)
        XCTAssertEqual(bridge.forwardCount, 1)
        XCTAssertEqual(bridge.reloadCount, 1)
        XCTAssertEqual(bridge.stopCount, 1)
    }

    func testBridgeStateMirrorsIntoNavStateAndFiresCallback() {
        let bridge = FakeCEFBridge()
        let engine = CEFEngine(bridge: bridge, url: nil)
        var fired: NavState?
        engine.onNavStateChange = { fired = $0 }

        var snap = NavState()
        snap.title = "Hi"
        snap.canGoBack = true
        snap.url = URL(string: "https://h.com")
        bridge.onNavState?(snap)

        XCTAssertEqual(engine.navState.title, "Hi")
        XCTAssertTrue(engine.navState.canGoBack)
        XCTAssertEqual(fired?.title, "Hi")
        XCTAssertEqual(fired?.url, URL(string: "https://h.com"))
    }

    func testHostViewIsBridgeView() {
        let bridge = FakeCEFBridge()
        let engine = CEFEngine(bridge: bridge, url: nil)
        XCTAssertTrue(engine.hostView === bridge.view)
    }

    /// navState must mirror even with no outer callback registered (the common
    /// case for a background engine), independent of onNavStateChange.
    func testNavStateMirrorsWithoutOuterCallback() {
        let bridge = FakeCEFBridge()
        let engine = CEFEngine(bridge: bridge, url: nil)
        var snap = NavState()
        snap.title = "Solo"
        bridge.onNavState?(snap)
        XCTAssertEqual(engine.navState.title, "Solo")
    }

    // MARK: - Factory (the bridge-maker is the one seam the libcef shim fills)

    func testFactoryBuildsCEFEngineAndLoadsAppURL() {
        let bridge = FakeCEFBridge()
        let factory = CEFEngineFactory(makeBridge: { _ in bridge })
        let app = WebApp(title: "T", urlString: "https://f.com")

        let engine = factory.makeEngine(for: app)

        XCTAssertTrue(engine is CEFEngine)
        XCTAssertTrue(engine.hostView === bridge.view)
        XCTAssertEqual(bridge.loaded, [URL(string: "https://f.com")!])
    }
}
