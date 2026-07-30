import AppKit
import XCTest
@testable import Peekr

@MainActor
final class WebViewManagerEngineSwitchTests: XCTestCase {
    private final class FakeEngine: WebEngine {
        let hostView = NSView()
        var navState = NavState()
        var onNavStateChange: ((NavState) -> Void)?
        private(set) var closeCount = 0

        func load(_ url: URL) {}
        func goBack() {}
        func goForward() {}
        func reload() {}
        func stopLoading() {}
        func close() { closeCount += 1 }
        func iconLinkURLs() async -> [URL] { [] }
    }

    private final class FakeFactory: WebEngineFactory {
        private(set) var engines: [FakeEngine] = []

        func makeEngine(for app: WebApp) -> WebEngine {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }
    }

    func testReplacingFactoryClosesCachedEngineAndRecreatesActiveTab() async {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-manager-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let oldFactory = FakeFactory()
        let newFactory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: oldFactory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        let activeID = model.apps[0].id
        manager.activate(activeID)
        let oldView = manager.view(for: activeID)

        manager.replaceFactory(newFactory)
        await Task.yield()

        XCTAssertEqual(oldFactory.engines.count, 1)
        XCTAssertEqual(oldFactory.engines[0].closeCount, 1)
        XCTAssertEqual(newFactory.engines.count, 1)
        XCTAssertEqual(manager.state.currentID, activeID)
        XCTAssertFalse(manager.view(for: activeID) === oldView)
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
        let secondID = model.apps[1].id
        manager.activate(firstID)
        manager.activate(secondID)

        manager.closeAll()

        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertEqual(factory.engines.map(\.closeCount), [1, 1])
        XCTAssertNil(manager.state.currentID)
        XCTAssertNil(manager.view(for: firstID))
        XCTAssertNil(manager.view(for: secondID))
    }
}
