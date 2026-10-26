import XCTest
@testable import Peekr

@MainActor
final class SessionRestoreTests: XCTestCase {
    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-\(name)-\(UUID().uuidString).json")
    }

    private func makeModel(
        storeURL: URL,
        profileURL: URL,
        recentlyClosedURL: URL
    ) -> AppModel {
        AppModel(
            store: AppStore(fileURL: storeURL),
            profileStore: ProfileStore(fileURL: profileURL),
            recentlyClosedStore: RecentlyClosedStore(fileURL: recentlyClosedURL)
        )
    }

    func testStartupBehaviorDecodesLegacyAndUnknownValues() throws {
        XCTAssertEqual(StartupBehavior.newTab.rawValue, "newTab")
        XCTAssertEqual(StartupBehavior.continueWhereLeftOff.rawValue, "continueWhereLeftOff")

        let missing = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.startupBehavior, .newTab)

        let legacy = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(#"{"startupBehavior":"continueWhereLeftOff"}"#.utf8)
        )
        XCTAssertEqual(legacy.startupBehavior, .continueWhereLeftOff)

        let unknown = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(#"{"startupBehavior":"sometimes"}"#.utf8)
        )
        XCTAssertEqual(unknown.startupBehavior, .newTab)

        var data = SettingsData()
        data.homePage = "https://example.com"
        data.startupBehavior = .homePage
        let encoded = try JSONEncoder().encode(data)
        XCTAssertEqual(try JSONDecoder().decode(SettingsData.self, from: encoded), data)
    }

    func testRecentlyClosedStoreRoundTripsAndCapsAt25() throws {
        let fileURL = temporaryFile("recently-closed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RecentlyClosedStore(fileURL: fileURL)

        XCTAssertTrue(store.load().isEmpty)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.load().isEmpty)

        let entry = ClosedTab(
            app: WebApp(title: "Example", urlString: "https://example.com"),
            workspaceID: UUID(),
            groupID: nil,
            topLevelIndex: 0,
            childIndex: nil
        )
        store.save([entry])
        XCTAssertEqual(store.load(), [entry])

        let many = (0..<30).map { index in
            ClosedTab(
                app: WebApp(title: "Tab \(index)", urlString: "https://example.com/\(index)"),
                workspaceID: UUID(),
                groupID: index.isMultiple(of: 2) ? UUID() : nil,
                topLevelIndex: index,
                childIndex: index.isMultiple(of: 2) ? 1 : nil
            )
        }
        store.save(many)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 25)
        XCTAssertEqual(loaded, Array(many.suffix(25)))
    }

    func testClosingNormalTabPersistsAndReopensAfterRelaunch() throws {
        let storeURL = temporaryFile("session-apps")
        let profileURL = temporaryFile("session-profiles")
        let recentlyClosedURL = temporaryFile("session-closed")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
            try? FileManager.default.removeItem(at: recentlyClosedURL)
        }

        let model = makeModel(
            storeURL: storeURL,
            profileURL: profileURL,
            recentlyClosedURL: recentlyClosedURL
        )
        let first = model.addApp(title: "First", urlString: "https://first.example")
        let second = model.addApp(title: "Second", urlString: "https://second.example")
        model.removeApp(first.id)
        model.removeApp(second.id)

        XCTAssertTrue(model.hasRecentlyClosedTabs)
        XCTAssertEqual(
            RecentlyClosedStore(fileURL: recentlyClosedURL).load().map(\.app.urlString),
            ["https://first.example", "https://second.example"]
        )

        let relaunched = makeModel(
            storeURL: storeURL,
            profileURL: profileURL,
            recentlyClosedURL: recentlyClosedURL
        )
        XCTAssertTrue(relaunched.hasRecentlyClosedTabs)
        let reopened = try XCTUnwrap(relaunched.reopenLastClosedTab())
        XCTAssertEqual(reopened.urlString, "https://second.example")
        XCTAssertEqual(reopened.title, "Second")
        XCTAssertEqual(relaunched.selectedID, reopened.id)
        XCTAssertEqual(relaunched.activeWorkspace.tabs.first(where: { $0.id == reopened.id })?.title, "Second")
        XCTAssertEqual(
            RecentlyClosedStore(fileURL: recentlyClosedURL).load().map(\.app.urlString),
            ["https://first.example"]
        )
    }

    func testClosingPrivateSpaceTabDoesNotPersist() throws {
        let storeURL = temporaryFile("private-session-apps")
        let profileURL = temporaryFile("private-session-profiles")
        let recentlyClosedURL = temporaryFile("private-session-closed")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
            try? FileManager.default.removeItem(at: recentlyClosedURL)
        }

        let model = makeModel(
            storeURL: storeURL,
            profileURL: profileURL,
            recentlyClosedURL: recentlyClosedURL
        )
        model.addPrivateWorkspace()
        let secret = model.addApp(title: "Secret", urlString: "https://secret.example")
        model.removeApp(secret.id)

        XCTAssertFalse(model.hasRecentlyClosedTabs)
        XCTAssertTrue(RecentlyClosedStore(fileURL: recentlyClosedURL).load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recentlyClosedURL.path))
    }

    func testSelectOrAddNewTabPageSelectsExistingAndAddsWhenAbsent() throws {
        let storeURL = temporaryFile("new-tab-page-apps")
        let profileURL = temporaryFile("new-tab-page-profiles")
        let recentlyClosedURL = temporaryFile("new-tab-page-closed")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
            try? FileManager.default.removeItem(at: recentlyClosedURL)
        }

        let model = makeModel(
            storeURL: storeURL,
            profileURL: profileURL,
            recentlyClosedURL: recentlyClosedURL
        )
        let initialCount = model.apps.count
        let added = model.selectOrAddNewTabPage()

        XCTAssertEqual(added.urlString, InternalPage.newTab.urlString)
        XCTAssertEqual(model.apps.count, initialCount + 1)
        XCTAssertEqual(model.selectedID, added.id)

        let other = try XCTUnwrap(model.apps.first(where: { $0.id != added.id }))
        model.select(other.id)

        let selected = model.selectOrAddNewTabPage()
        XCTAssertEqual(selected.id, added.id)
        XCTAssertEqual(model.selectedID, added.id)
        XCTAssertEqual(model.apps.count, initialCount + 1)
        XCTAssertEqual(
            model.apps.filter { $0.urlString == InternalPage.newTab.urlString }.count,
            1
        )
    }
}
