import AppKit
import XCTest
@testable import Peekr

@MainActor
final class WebViewManagerLifecycleTests: XCTestCase {
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

        func publish(_ state: NavState) {
            navState = state
            onNavStateChange?(state)
        }
    }

    private final class FakeFactory: WebEngineFactory {
        private(set) var engines: [FakeEngine] = []

        func makeEngine(for app: WebApp) -> WebEngine {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }
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
}
