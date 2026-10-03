import AppKit
import XCTest
@testable import Peekr

@MainActor
final class WebViewManagerLifecycleTests: XCTestCase {
    private final class FakeEngine: WebEngine {
        let hostView = NSView()
        var navState = NavState()
        var onNavStateChange: ((NavState) -> Void)?
        var onDownloadChange: ((WebDownload) -> Void)?
        var activity = WebActivitySnapshot(audio: .unknown)
        private(set) var closeCount = 0
        private(set) var reloadCount = 0
        private(set) var loadedURLs: [URL] = []
        var zoomLevel = 0.0
        var isAudioMuted = false
        private(set) var canceledDownloadIDs: [UInt32] = []

        func load(_ url: URL) { loadedURLs.append(url) }
        func goBack() {}
        func goForward() {}
        func reload() { reloadCount += 1 }
        func stopLoading() {}
        func zoomIn() { zoomLevel += 1 }
        func zoomOut() { zoomLevel -= 1 }
        func zoomReset() { zoomLevel = 0 }
        func cancelDownload(_ id: UInt32) { canceledDownloadIDs.append(id) }
        func close() { closeCount += 1 }
        func iconLinkURLs() async -> [URL] { [] }

        func publish(_ state: NavState) {
            navState = state
            onNavStateChange?(state)
        }

        func publish(_ download: WebDownload) {
            onDownloadChange?(download)
        }
    }

    private final class FakeFactory: WebEngineFactory {
        private(set) var engines: [FakeEngine] = []
        private(set) var profiles: [BrowserProfile] = []

        func makeEngine(for app: WebApp, profile: BrowserProfile) -> WebEngine {
            let engine = FakeEngine()
            engines.append(engine)
            profiles.append(profile)
            return engine
        }
    }

    func testEngineReceivesTheWorkspaceProfile() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-profile-\(UUID().uuidString).json")
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-profiles-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
        }
        let model = AppModel(
            store: AppStore(fileURL: storeURL),
            profileStore: ProfileStore(fileURL: profileURL)
        )
        let profile = try XCTUnwrap(model.createProfile(name: "Work"))
        let workspaceID = model.activeWorkspaceID
        XCTAssertTrue(model.rebindWorkspace(workspaceID, to: profile.id))

        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        manager.activate(model.apps[0].id)

        XCTAssertEqual(factory.profiles.map(\.id), [profile.id])
        XCTAssertEqual(factory.profiles.first?.storageKey, profile.storageKey)
    }

    func testHiddenIdleSilentBackgroundTabSleepsAndWakesWithItsURL() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-sleep-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let firstID = model.apps[0].id
        let second = model.addApp(title: "Second", urlString: "https://second.example", select: false)
        var clock = Date(timeIntervalSince1970: 10_000)
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore(),
            hibernationPolicy: HibernationPolicy(idleThreshold: 600),
            now: { clock }
        )

        manager.activate(firstID)
        manager.activate(second.id)
        manager.activate(firstID)
        factory.engines[1].activity = WebActivitySnapshot(audio: .silent)
        manager.setPanelVisible(false)
        clock = clock.addingTimeInterval(601)

        XCTAssertEqual(manager.sweep(now: clock), [second.id])
        XCTAssertEqual(factory.engines[1].closeCount, 1)
        XCTAssertNil(manager.view(for: second.id))

        manager.wake(second.id)
        XCTAssertEqual(factory.engines.count, 3)
        XCTAssertEqual(factory.engines[2].loadedURLs, [URL(string: "https://second.example")!])
        XCTAssertEqual(model.tab(second.id)?.urlString, "https://second.example")
    }

    func testUnknownAudioAndKeepAwakeAreProtectedFromAutomaticSleep() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-protected-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let firstID = model.apps[0].id
        let unknown = model.addApp(title: "Unknown", urlString: "https://unknown.example", select: false)
        let kept = model.addApp(title: "Kept", urlString: "https://kept.example", select: false)
        model.toggleKeepAwake(kept.id)
        var clock = Date(timeIntervalSince1970: 10_000)
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore(),
            hibernationPolicy: HibernationPolicy(idleThreshold: 600),
            now: { clock }
        )
        manager.activate(firstID)
        manager.activate(unknown.id)
        manager.activate(kept.id)
        manager.activate(firstID)
        factory.engines[1].activity = WebActivitySnapshot(audio: .unknown)
        factory.engines[2].activity = WebActivitySnapshot(audio: .silent)
        manager.setPanelVisible(false)
        clock = clock.addingTimeInterval(601)

        XCTAssertTrue(manager.sweep(now: clock).isEmpty)
        XCTAssertEqual(factory.engines[1].closeCount, 0)
        XCTAssertEqual(factory.engines[2].closeCount, 0)
    }

    func testSettledNavigationFactsArePersistedForRecovery() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-navigation-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        let id = model.apps[0].id
        manager.activate(id)

        factory.engines[0].publish(NavState(
            isLoading: false,
            url: URL(string: "https://settled.example/path"),
            title: "Settled page"
        ))

        XCTAssertEqual(model.tab(id)?.urlString, "https://settled.example/path")
        XCTAssertEqual(model.tab(id)?.title, "Settled page")
    }

    func testCloseAllForceClosesEveryCachedEngineAndClearsSelection() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        let firstID = model.apps[0].id
        let secondID = model.addApp(
            title: "Second",
            urlString: "https://second.example"
        ).id
        manager.activate(firstID)
        manager.activate(secondID)

        manager.closeAll()

        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertEqual(factory.engines.map(\.closeCount), [1, 1])
        XCTAssertNil(manager.state.currentID)
        XCTAssertNil(manager.view(for: firstID))
        XCTAssertNil(manager.view(for: secondID))
    }

    func testClosingCurrentTabDiscardsItsEngineAndActivatesModelFallback() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        model.onRemove = { manager.discard($0) }
        let firstID = model.apps[0].id
        let secondID = model.addApp(
            title: "Second",
            urlString: "https://second.example"
        ).id
        model.select(firstID)
        manager.activate(firstID)

        model.removeApp(firstID)

        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertEqual(factory.engines[0].closeCount, 1)
        XCTAssertEqual(manager.state.currentID, secondID)
        XCTAssertNotNil(manager.view(for: secondID))
        XCTAssertNil(manager.view(for: firstID))
    }

    func testBackgroundNewTabKeepsCurrentSelectionAndLoadsLazily() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        let firstID = model.apps[0].id
        manager.activate(firstID)

        manager.openInNewTab(urlString: "https://opened.example", foreground: false)

        let opened = model.allTabs.first { $0.urlString == "https://opened.example" }
        XCTAssertNotNil(opened)
        XCTAssertEqual(model.selectedID, firstID)
        XCTAssertEqual(manager.state.currentID, firstID)
        // Background tabs start lazily: no engine until first activation.
        XCTAssertNil(manager.view(for: opened!.id))
    }

    func testMirrorsLoadFailureAndRecoversRendererOnceBeforeExplicitRetry() async {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        let id = model.apps[0].id
        manager.activate(id)
        let failure = WebLoadFailure(
            code: -105,
            message: "ERR_NAME_NOT_RESOLVED",
            url: URL(string: "https://missing.example")
        )

        factory.engines[0].publish(NavState(url: failure.url, loadError: failure))

        XCTAssertEqual(manager.state.loadError, failure)
        manager.retryCurrentPage()
        XCTAssertEqual(factory.engines[0].reloadCount, 1)

        factory.engines[0].publish(NavState(url: failure.url))
        XCTAssertNil(manager.state.loadError)

        let rendererFailure = WebRendererFailure(reason: "crashed", code: 139)
        factory.engines[0].publish(NavState(url: failure.url, rendererFailure: rendererFailure))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertEqual(factory.engines[0].closeCount, 1)
        XCTAssertEqual(manager.state.pageLifecycle, .live)

        // A delayed callback from the closed engine cannot overwrite the
        // replacement engine's lifecycle or failure state.
        factory.engines[0].publish(NavState(url: failure.url, rendererFailure: rendererFailure))
        XCTAssertNil(manager.state.rendererFailure)

        factory.engines[1].publish(NavState(url: failure.url, rendererFailure: rendererFailure))
        XCTAssertEqual(manager.state.rendererFailure, rendererFailure)
        XCTAssertEqual(manager.state.pageLifecycle, .crashed)
        manager.retryCurrentPage()
        XCTAssertEqual(factory.engines.count, 3)
        XCTAssertEqual(factory.engines[1].closeCount, 1)
        XCTAssertEqual(manager.state.pageLifecycle, .live)
    }

    func testForegroundNewTabSelectsAndActivates() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        manager.activate(model.apps[0].id)

        manager.openInNewTab(urlString: "https://opened.example", foreground: true)

        let opened = model.allTabs.first { $0.urlString == "https://opened.example" }
        XCTAssertEqual(model.selectedID, opened?.id)
        XCTAssertEqual(manager.state.currentID, opened?.id)
        XCTAssertNotNil(manager.view(for: opened!.id))
    }

    func testOmniboxCommandReturnOpensBackgroundTab() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        let firstID = model.apps[0].id
        manager.activate(firstID)

        manager.loadAddressInBackgroundTab("example.com")

        XCTAssertTrue(model.allTabs.contains { $0.urlString == "https://example.com" })
        XCTAssertEqual(model.selectedID, firstID)
        XCTAssertEqual(manager.state.currentID, firstID)
    }

    func testCrossHostNavigationReplacesStaleTitleBeforeDestinationTitleArrives() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        let activeID = model.apps[0].id
        manager.activate(activeID)

        let destination = URL(string: "https://x.com/home")!
        factory.engines[0].publish(NavState(
            isLoading: true,
            progress: 0.2,
            url: destination,
            title: "Google"
        ))

        XCTAssertEqual(model.tab(activeID)?.displayName, "x.com")
        XCTAssertEqual(manager.state.urlString, destination.absoluteString)

        factory.engines[0].publish(NavState(
            isLoading: true,
            progress: 0.4,
            url: destination,
            title: "Home / X"
        ))

        XCTAssertEqual(model.tab(activeID)?.displayName, "Home / X")
    }

    func testDownloadEventsReachTheSharedDownloadStore() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        manager.activate(model.apps[0].id)

        factory.engines[0].publish(WebDownload(
            id: 12,
            url: URL(string: "https://example.com/file.zip"),
            fileName: "file.zip",
            receivedBytes: 50,
            totalBytes: 100,
            state: .downloading,
            location: nil
        ))

        XCTAssertEqual(manager.downloads.activeCount, 1)
        XCTAssertEqual(manager.downloads.records.first?.fileName, "file.zip")
    }

    func testSiteZoomIsPersistedByOriginAndRestoredForAnotherEngine() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let zoomURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-zoom-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: zoomURL)
        }
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model, factory: factory, badges: BadgeStore(), icons: IconStore(),
            zoomStore: ZoomStore(fileURL: zoomURL)
        )
        let id = model.apps[0].id
        var app = try! XCTUnwrap(model.tab(id))
        app.urlString = "https://zoom.example/article"
        model.update(app)
        manager.activate(id)
        factory.engines[0].publish(NavState(url: URL(string: "https://zoom.example/article")!))
        manager.zoomIn()
        XCTAssertEqual(factory.engines[0].zoomLevel, 1)

        let secondFactory = FakeFactory()
        let secondManager = WebViewManager(
            model: model, factory: secondFactory, badges: BadgeStore(), icons: IconStore(),
            zoomStore: ZoomStore(fileURL: zoomURL)
        )
        secondManager.activate(id)
        XCTAssertEqual(secondFactory.engines[0].zoomLevel, 1)
    }

    func testMuteToggleUpdatesTabAndEngine() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(model: model, factory: factory, badges: BadgeStore(), icons: IconStore())
        let id = model.apps[0].id
        manager.activate(id)

        manager.toggleMute(id)
        XCTAssertTrue(factory.engines[0].isAudioMuted)
        XCTAssertTrue(model.tab(id)?.isMuted == true)
        manager.toggleMute(id)
        XCTAssertFalse(factory.engines[0].isAudioMuted)
        XCTAssertFalse(model.tab(id)?.isMuted == true)
    }

    func testCancelDownloadRoutesToTheEngineThatStartedIt() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(model: model, factory: factory, badges: BadgeStore(), icons: IconStore())
        manager.activate(model.apps[0].id)

        factory.engines[0].publish(WebDownload(
            id: 22, url: URL(string: "https://example.com/file.zip"), fileName: "file.zip",
            receivedBytes: 1, totalBytes: 10, state: .downloading, location: nil
        ))
        manager.cancelDownload(22)

        XCTAssertEqual(factory.engines[0].canceledDownloadIDs, [22])
    }
}
