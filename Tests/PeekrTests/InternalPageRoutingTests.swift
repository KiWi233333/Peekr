import AppKit
import XCTest
@testable import Peekr

@MainActor
final class InternalPageRoutingTests: XCTestCase {
    private final class FakeEngine: WebEngine {
        let hostView = NSView()
        var navState = NavState()
        var onNavStateChange: ((NavState) -> Void)?
        var onDownloadChange: ((WebDownload) -> Void)?
        var onFindResult: ((FindResult) -> Void)?
        var activity = WebActivitySnapshot(audio: .unknown)
        var zoomLevel = 0.0
        var isAudioMuted = false
        private(set) var pausedDownloadIDs: [UInt32] = []
        private(set) var resumedDownloadIDs: [UInt32] = []
        private(set) var canceledDownloadIDs: [UInt32] = []

        func load(_ url: URL) { navState.url = url }
        func goBack() {}
        func goForward() {}
        func reload() {}
        func stopLoading() {}
        func zoomIn() { zoomLevel += 1 }
        func zoomOut() { zoomLevel -= 1 }
        func zoomReset() { zoomLevel = 0 }
        func cancelDownload(_ id: UInt32) { canceledDownloadIDs.append(id) }
        func pauseDownload(_ id: UInt32) { pausedDownloadIDs.append(id) }
        func resumeDownload(_ id: UInt32) { resumedDownloadIDs.append(id) }
        func close() {}
        func iconLinkURLs() async -> [URL] { [] }

        func publish(_ state: NavState) {
            navState = state
            onNavStateChange?(state)
        }

        func publish(_ download: WebDownload) {
            onDownloadChange?(download)
        }

        func publishFind(_ result: FindResult) {
            onFindResult?(result)
        }
    }

    private final class FakeFactory: WebEngineFactory {
        private(set) var engines: [FakeEngine] = []

        func makeEngine(for app: WebApp, profile: BrowserProfile) -> WebEngine {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }
    }

    private func makeManager() -> (AppModel, FakeFactory, WebViewManager) {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-internal-\(UUID().uuidString).json")
        let downloadsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-internal-downloads-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore(),
            downloadStore: DownloadStore(fileURL: downloadsURL)
        )
        return (model, factory, manager)
    }

    func testActivatingInternalPageDoesNotCreateAnEngine() {
        let (model, factory, manager) = makeManager()
        let tab = model.addApp(
            title: "New Tab",
            urlString: InternalPage.newTab.urlString,
            select: true
        )

        manager.activate(tab.id)

        XCTAssertEqual(manager.state.internalPage, .newTab)
        XCTAssertTrue(factory.engines.isEmpty)
    }

    func testOpenInternalPageAndBackRestoresTheEngineState() {
        let (model, factory, manager) = makeManager()
        let tab = model.addApp(
            title: "Example",
            urlString: "https://example.com/",
            select: true
        )
        manager.activate(tab.id)
        let url = URL(string: "https://example.com/page")!
        factory.engines[0].publish(NavState(
            canGoBack: true,
            isLoading: false,
            progress: 1,
            url: url,
            title: "Example"
        ))

        manager.openInternalPage(.history)
        XCTAssertEqual(manager.state.internalPage, .history)

        manager.goBack()

        XCTAssertNil(manager.state.internalPage)
        XCTAssertEqual(manager.state.urlString, url.absoluteString)
        XCTAssertEqual(manager.state.title, "Example")
        XCTAssertTrue(manager.state.canGoBack)
    }

    func testTypingAnInternalURLShowsThePage() {
        let (model, _, manager) = makeManager()
        manager.activate(model.apps[0].id)

        manager.loadAddress("peekr://downloads")

        XCTAssertEqual(manager.state.internalPage, .downloads)
    }

    func testNewTabUsesAnEmptyOmniboxEditingAddress() {
        XCTAssertEqual(InternalPage.newTab.omniboxEditingAddress, "")
        XCTAssertEqual(InternalPage.history.omniboxEditingAddress, "peekr://history")
        XCTAssertEqual(
            InternalPage.siteSettings("https://example.com").omniboxEditingAddress,
            "peekr://site-settings?origin=https://example.com"
        )
    }

    func testSearchFromNativeNewTabKeepsTheSameSelectedTab() {
        let (model, factory, manager) = makeManager()
        let tab = model.addBlankTab()
        manager.activate(tab.id)

        manager.loadAddress("example.com")

        XCTAssertEqual(model.selectedID, tab.id)
        XCTAssertEqual(manager.state.currentID, tab.id)
        XCTAssertNil(manager.state.internalPage)
        XCTAssertEqual(manager.state.urlString, "https://example.com")
        XCTAssertEqual(manager.state.title, "example.com")
        XCTAssertTrue(manager.state.isLoading)
        XCTAssertEqual(manager.state.progress, 0)
        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertEqual(factory.engines[0].navState.url?.absoluteString, "https://example.com")
        XCTAssertEqual(model.tab(tab.id)?.urlString, InternalPage.newTab.urlString)
    }

    func testHistoryNavigationFromInternalPageKeepsTheSameSelectedTab() {
        let (model, factory, manager) = makeManager()
        let tab = model.addApp(title: "Start", urlString: "https://start.example", select: true)
        manager.activate(tab.id)
        manager.openInternalPage(.history)

        manager.loadAddress("https://example.com/article")

        XCTAssertEqual(model.selectedID, tab.id)
        XCTAssertEqual(manager.state.currentID, tab.id)
        XCTAssertNil(manager.state.internalPage)
        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertEqual(factory.engines[0].navState.url?.absoluteString, "https://example.com/article")
    }

    func testNavigationReunitesSelectionWithThePresentedTab() {
        let (model, _, manager) = makeManager()
        let presented = model.addBlankTab()
        let other = model.addBlankTab()
        manager.activate(presented.id)
        model.select(other.id)
        XCTAssertNotEqual(model.selectedID, manager.state.currentID)

        manager.loadAddress("https://example.com")

        XCTAssertEqual(model.selectedID, presented.id)
        XCTAssertEqual(manager.state.currentID, presented.id)
    }

    func testDownloadPauseAndResumeUpdateEngineAndStore() {
        let (model, factory, manager) = makeManager()
        let tab = model.addApp(
            title: "Example",
            urlString: "https://example.com/",
            select: true
        )
        manager.activate(tab.id)
        factory.engines[0].publish(WebDownload(
            id: 41,
            url: URL(string: "https://example.com/file.zip"),
            fileName: "file.zip",
            receivedBytes: 10,
            totalBytes: 100,
            state: .downloading,
            location: nil
        ))

        manager.pauseDownload(41)
        XCTAssertEqual(factory.engines[0].pausedDownloadIDs, [41])
        XCTAssertTrue(manager.downloads.isPaused(41))

        manager.resumeDownload(41)
        XCTAssertEqual(factory.engines[0].resumedDownloadIDs, [41])
        XCTAssertFalse(manager.downloads.isPaused(41))
    }

    func testTabSearchToggleFlipsTheOverlayState() {
        let (_, _, manager) = makeManager()

        manager.toggleTabSearch()
        XCTAssertTrue(manager.state.tabSearchOpen)

        manager.toggleTabSearch()
        XCTAssertFalse(manager.state.tabSearchOpen)
    }

    func testFindResultsReachTheFindBar() {
        let (model, factory, manager) = makeManager()
        let tab = model.addApp(
            title: "Example",
            urlString: "https://example.com/",
            select: true
        )
        manager.activate(tab.id)

        factory.engines[0].publishFind(
            FindResult(matches: 7, activeMatchOrdinal: 3, finalUpdate: true)
        )

        XCTAssertEqual(manager.findBar.matches, 7)
        XCTAssertEqual(manager.findBar.activeMatch, 3)
    }
}
