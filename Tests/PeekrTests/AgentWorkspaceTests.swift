import Foundation
import XCTest
@testable import Peekr

@MainActor
final class AgentWorkspaceTests: XCTestCase {
    func testAgentWorkspaceIsCreatedActiveAndOwnedByAgent() {
        let model = makeEmptyModel()

        let space = model.addAgentWorkspace(owner: "Claude Code", name: "Scrape leads")

        XCTAssertEqual(model.activeWorkspaceID, space.id)
        XCTAssertEqual(space.ownership, .agent)
        XCTAssertEqual(space.agentOwner, "Claude Code")
        XCTAssertTrue(space.isAgentOwned)
        XCTAssertEqual(space.tabs.count, 1, "agent spaces start with one blank tab")
    }

    func testTakeOverFlipsOwnershipToUserAndClearsAgentLabel() {
        let model = makeEmptyModel()
        let space = model.addAgentWorkspace(owner: "Claude Code")
        let tabID = space.selectedTabID

        model.takeOverWorkspace(space.id)

        let taken = model.workspaces.first { $0.id == space.id }
        XCTAssertEqual(taken?.ownership, .user)
        XCTAssertEqual(taken?.agentOwner, "")
        XCTAssertFalse(taken?.isAgentOwned ?? true)
        XCTAssertEqual(taken?.selectedTabID, tabID, "taking over keeps the space's tabs")
    }

    func testTakeOverOnUserOwnedSpaceIsNoOp() {
        let model = makeEmptyModel()
        let userSpaceID = model.activeWorkspaceID

        model.takeOverWorkspace(userSpaceID)

        let space = model.workspaces.first { $0.id == userSpaceID }
        XCTAssertEqual(space?.ownership, .user, "a user space never changes hands silently")
        XCTAssertEqual(space?.agentOwner, "")
    }

    func testLegacyWorkspaceJSONWithoutOwnershipDecodesAsUserOwned() throws {
        // A v2 sidebar file written before agent spaces existed: no
        // `ownership`/`agentOwner` keys anywhere.
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "workspaces": [
            {
              "id": "\(UUID().uuidString)",
              "name": "Daily",
              "symbol": "square.stack",
              "tabs": [
                {
                  "id": "\(UUID().uuidString)",
                  "title": "Example",
                  "urlString": "https://example.com"
                }
              ]
            }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-agent-legacy-\(UUID().uuidString).json")
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let data = AppStore(fileURL: url).load()

        XCTAssertEqual(data.workspaces.count, 1)
        XCTAssertEqual(data.workspaces[0].ownership, .user)
        XCTAssertEqual(data.workspaces[0].agentOwner, "")
    }

    func testAgentAccessSettingsRoundTripAndTolerantDecode() throws {
        var data = SettingsData()
        data.agentAccessEnabled = true
        data.agentDebugPort = 9333
        let encoded = try JSONEncoder().encode(data)

        let decoded = try JSONDecoder().decode(SettingsData.self, from: encoded)
        XCTAssertTrue(decoded.agentAccessEnabled)
        XCTAssertEqual(decoded.agentDebugPort, 9333)

        // Older settings files predate both keys entirely.
        let legacy = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.agentAccessEnabled)
        XCTAssertEqual(legacy.agentDebugPort, 9223)
    }

    func testDiscoveryFilePublishAndRevoke() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-agent-discovery-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        AgentDiscovery.publish(port: 9223, to: url)
        let published = try JSONDecoder().decode(
            AgentDiscovery.Discovery.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(published.port, 9223)
        XCTAssertEqual(published.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(published.schemaVersion, AgentDiscovery.schemaVersion)

        AgentDiscovery.revoke(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCefConfigurationCarriesAgentDebugPortOnlyWhenEnabled() {
        var data = SettingsData()
        data.agentAccessEnabled = true
        data.agentDebugPort = 9333

        let enabled = PeekrApp.makeCefConfiguration(data)
        XCTAssertEqual(enabled.remoteDebuggingPort, 9333)

        data.agentAccessEnabled = false
        XCTAssertNil(PeekrApp.makeCefConfiguration(data).remoteDebuggingPort)

        data.agentAccessEnabled = true
        data.agentDebugPort = 0
        XCTAssertNil(
            PeekrApp.makeCefConfiguration(data).remoteDebuggingPort,
            "a zero/invalid port must not open CEF debugging"
        )
    }

    private func makeEmptyModel() -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-agent-\(UUID().uuidString).json")
        let store = AppStore(fileURL: url)
        store.save(WorkspacesData(workspaces: [Workspace(tabs: [])]))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AppModel(store: store)
    }

    func testAddAppToSpecificWorkspaceLandsWithoutTouchingSelection() {
        let model = makeEmptyModel()
        let agent = model.addAgentWorkspace(owner: "Claude Code", name: "sync")
        let agentID = agent.id

        // The user's original workspace keeps its selection untouched.
        let originalSelected = model.workspaces.first { $0.id != agentID }?.selectedTabID
        let added = model.addApp(title: "Agent Page", urlString: "https://example.com/x", toWorkspace: agentID)

        XCTAssertNotNil(added)
        let workspace = model.workspaces.first { $0.id == agentID }
        XCTAssertEqual(workspace?.tabs.last?.id, added?.id)
        XCTAssertEqual(workspace?.sidebarItems.last?.referenceID, added?.id)
        XCTAssertNotEqual(model.selectedID, added?.id, "sync-added tabs must not steal selection")
        XCTAssertEqual(model.workspaces.first { $0.id != agentID }?.selectedTabID, originalSelected)

        // Unknown workspace is rejected instead of crashing.
        XCTAssertNil(model.addApp(title: "x", urlString: "https://a.b", toWorkspace: UUID()))
    }

}
