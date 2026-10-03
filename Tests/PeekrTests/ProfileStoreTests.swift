import Foundation
import XCTest
@testable import Peekr

final class ProfileStoreTests: XCTestCase {
    func testMissingRegistryCreatesStableDefaultProfile() {
        let url = temporaryURL()
        let store = ProfileStore(fileURL: url)
        let registry = store.load()

        XCTAssertEqual(registry.profiles.count, 1)
        XCTAssertEqual(registry.profiles[0].id, BrowserProfile.defaultID)
        XCTAssertEqual(registry.profiles[0].storageKey, BrowserProfile.defaultStorageKey)
        XCTAssertTrue(registry.profiles[0].isDefault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        remove(url)
    }

    func testInvalidRegistryRepairsDefaultAndStorageKeys() throws {
        let url = temporaryURL()
        let profileID = UUID()
        let invalid = """
        {
          "schemaVersion": 1,
          "profiles": [
            {"id":"\(profileID.uuidString)","name":"Work","storageKey":"../escape"},
            {"id":"\(profileID.uuidString)","name":"Duplicate","storageKey":"other"}
          ]
        }
        """
        try invalid.write(to: url, atomically: true, encoding: .utf8)

        let profiles = ProfileStore(fileURL: url).load().profiles

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].id, BrowserProfile.defaultID)
        XCTAssertEqual(profiles[1].id, profileID)
        XCTAssertEqual(profiles[1].storageKey, BrowserProfile.storageKey(for: profileID))
        XCTAssertFalse(profiles[1].storageKey.contains(".."))
        remove(url)
    }

    func testRenameKeepsIDAndStorageKeyStable() {
        let url = temporaryURL()
        let store = ProfileStore(fileURL: url)
        let created = try! XCTUnwrap(store.create(name: "Work"))

        let renamed = store.rename(created.id, to: "Personal")

        XCTAssertEqual(renamed?.id, created.id)
        XCTAssertEqual(renamed?.storageKey, created.storageKey)
        XCTAssertEqual(renamed?.name, "Personal")
        remove(url)
    }

    func testBoundProfileCannotBeDeleted() {
        let url = temporaryURL()
        let store = ProfileStore(fileURL: url)
        let created = try! XCTUnwrap(store.create(name: "Work"))

        XCTAssertFalse(store.delete(created.id, boundWorkspaceIDs: [UUID()]))
        XCTAssertNotNil(store.load().profiles.first { $0.id == created.id })
        XCTAssertFalse(store.delete(BrowserProfile.defaultID, boundWorkspaceIDs: []))
        XCTAssertTrue(store.delete(created.id, boundWorkspaceIDs: []))
        XCTAssertNil(store.load().profiles.first { $0.id == created.id })
        remove(url)
    }

    @MainActor
    func testOldWorkspaceDataGetsDefaultProfileAndCurrentSchema() throws {
        let url = temporaryURL()
        let workspaceID = UUID()
        let tabID = UUID()
        let legacy = """
        {
          "schemaVersion": 2,
          "workspaces": [{
            "id":"\(workspaceID.uuidString)",
            "name":"Daily",
            "tabs":[{"id":"\(tabID.uuidString)","title":"Example","urlString":"https://example.com"}]
          }]
        }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let model = AppModel(
            store: AppStore(fileURL: url),
            profileStore: ProfileStore(fileURL: temporaryURL())
        )

        XCTAssertEqual(model.workspaces[0].profileID, BrowserProfile.defaultID)
        XCTAssertEqual(model.workspaces[0].tabs[0].id, tabID)
        let migrated = try JSONDecoder().decode(
            WorkspacesData.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(migrated.schemaVersion, WorkspacesData.currentSchemaVersion)
        XCTAssertEqual(migrated.workspaces[0].profileID, BrowserProfile.defaultID)
        remove(url)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-profile-\(UUID().uuidString).json")
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        // The model test creates a second registry URL through its default
        // argument; cleanup is intentionally best-effort for temp files.
    }
}
