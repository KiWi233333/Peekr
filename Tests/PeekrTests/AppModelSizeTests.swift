import XCTest
@testable import Peekr

/// Writing a per-app panel size updates the active workspace's tab and persists
/// so the size is restored on next launch.
@MainActor
final class AppModelSizeTests: XCTestCase {
    private func tempStore() -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-test-\(UUID().uuidString).json")
        return (AppStore(fileURL: url), url)
    }

    func testSetPanelSizeUpdatesActiveTab() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(store: store)
        let app = model.addApp(title: "A", urlString: "https://a.com")

        model.setPanelSize(app.id, width: 680, height: 540)

        let updated = model.apps.first { $0.id == app.id }
        XCTAssertEqual(updated?.panelWidth, 680)
        XCTAssertEqual(updated?.panelHeight, 540)
    }

    func testSetPanelSizePersistsAcrossReload() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(store: store)
        let app = model.addApp(title: "A", urlString: "https://a.com")

        model.setPanelSize(app.id, width: 680, height: 540)

        let reloaded = AppModel(store: AppStore(fileURL: url))
        let found = reloaded.allTabs.first { $0.id == app.id }
        XCTAssertEqual(found?.panelWidth, 680)
        XCTAssertEqual(found?.panelHeight, 540)
    }

    func testSetAliasDrivesDisplayName() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(store: store)
        let app = model.addApp(title: "GitHub", urlString: "https://github.com")

        model.setAlias(app.id, to: "Work")

        let updated = model.apps.first { $0.id == app.id }
        XCTAssertEqual(updated?.alias, "Work")
        XCTAssertEqual(updated?.displayName, "Work")
    }

    func testRemoveAppFiresOnRemove() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(store: store)
        let app = model.addApp(title: "X", urlString: "https://x.com")
        var removed: UUID?
        model.onRemove = { removed = $0 }

        model.removeApp(app.id)

        XCTAssertEqual(removed, app.id)
    }
}
