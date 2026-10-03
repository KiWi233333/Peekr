import XCTest

@testable import Peekr

@MainActor
final class AgentTargetSyncTests: XCTestCase {
    private func setup() -> (AppModel, AgentTargetSync, FakeTargetTransport, UUID) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peekr-target-tests-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(store: AppStore(fileURL: url))
        let space = model.addAgentWorkspace(name: "test")
        let transport = FakeTargetTransport()
        return (model, AgentTargetSync(model: model, port: 1, transport: transport), transport, space.id)
    }

    func testOnlyExplicitlyCreatedTargetsBelongToSpace() async throws {
        let (model, bridge, transport, id) = setup()
        transport.live = [["id": "user", "type": "page", "url": "https://same.test/"]]
        let created = try await bridge.createTab(in: id, url: "https://same.test/")
        let other = model.addAgentWorkspace(name: "other")
        let listed = try await bridge.tabs(in: id)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["targetId"] as? String, created["targetId"] as? String)
        let foreign = try await bridge.tabs(in: other.id)
        XCTAssertTrue(foreign.isEmpty)
        do {
            try await bridge.closeTab(in: other.id, targetID: "owned-1")
            XCTFail("cross-space close allowed")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_TARGET_NOT_OWNED") }
        XCTAssertTrue(transport.closed.isEmpty)
    }

    func testHandoffBlocksCreateCloseAndList() async throws {
        let (model, bridge, transport, id) = setup()
        _ = try await bridge.createTab(in: id, url: "https://example.test/")
        _ = model.handOffWorkspace(id)
        do {
            _ = try await bridge.tabs(in: id)
            XCTFail("delegated list allowed")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_SPACE_USER_IN_CONTROL") }
        do {
            try await bridge.closeTab(in: id, targetID: "owned-1")
            XCTFail("delegated close allowed")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_SPACE_USER_IN_CONTROL") }
        XCTAssertTrue(transport.closed.isEmpty)
    }

    func testFinishPreservesUserTabsAndTransfersRetainedPages() async throws {
        let (model, bridge, transport, id) = setup()
        let userID = try XCTUnwrap(model.workspaces.first(where: { $0.id == id })?.tabs.first?.id)
        _ = try await bridge.createTab(in: id, url: "https://one.test/")
        _ = try await bridge.createTab(in: id, url: "https://two.test/")
        let closed = try await bridge.finish(id, keep: ["owned-2"])
        XCTAssertFalse(closed)
        XCTAssertEqual(transport.closed, ["owned-1"])
        XCTAssertNotNil(model.tab(userID))
        XCTAssertEqual(model.workspaces.first(where: { $0.id == id })?.ownership, .user)
    }

    func testTakeoverDuringCreateDisposesOnlyNewTarget() async throws {
        let (model, bridge, transport, id) = setup()
        transport.onCreate = { model.takeOverWorkspace(id) }
        do {
            _ = try await bridge.createTab(in: id, url: "https://example.test/")
            XCTFail("takeover ignored")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_SPACE_USER_IN_CONTROL") }
        XCTAssertEqual(transport.closed, ["owned-1"])
    }

    func testTabLimitRejectsBeforeCreatingAndClosingRestoresBudget() async throws {
        let (_, bridge, transport, id) = setup()
        for index in 0..<bridge.tabLimit {
            _ = try await bridge.createTab(in: id, url: "https://example.test/\(index)")
        }
        do {
            _ = try await bridge.createTab(in: id, url: "https://extra.test")
            XCTFail("budget ignored")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_TAB_LIMIT") }
        XCTAssertEqual(transport.live.count, bridge.tabLimit)
        try await bridge.closeTab(in: id, targetID: "owned-1")
        _ = try await bridge.createTab(in: id, url: "https://replacement.test")
        XCTAssertEqual(transport.live.count, bridge.tabLimit)
    }

    func testFinishRejectsReentrantWritesForEntireTransaction() async throws {
        let (_, bridge, transport, id) = setup()
        _ = try await bridge.createTab(in: id, url: "https://one.test")
        _ = try await bridge.createTab(in: id, url: "https://two.test")
        var rejections = 0
        transport.onClose = {
            do {
                _ = try await bridge.createTab(in: id, url: "https://unexpected.test")
                XCTFail("reentrant write")
            } catch let error as AgentBridgeError {
                XCTAssertEqual(error.code, "PEEKR_BROWSER_BUSY")
                rejections += 1
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        _ = try await bridge.finish(id, keep: [])
        XCTAssertEqual(rejections, 2)
        XCTAssertTrue(transport.live.isEmpty)
    }

    func testTransferredTabIsNeverListedClosedOrActivatedByOldSpace() async throws {
        let (model, bridge, transport, id) = setup()
        let created = try await bridge.createTab(in: id, url: "https://one.test")
        let tabID = try XCTUnwrap(UUID(uuidString: created["tabId"] as? String ?? ""))
        let tab = try XCTUnwrap(model.tab(tabID))
        let source = try XCTUnwrap(model.workspaces.firstIndex(where: { $0.id == id }))
        model.workspaces[source].tabs.removeAll(where: { $0.id == tabID })
        let destination = model.addWorkspace()
        let destinationIndex = try XCTUnwrap(model.workspaces.firstIndex(where: { $0.id == destination.id }))
        model.workspaces[destinationIndex].tabs.append(tab)
        let listed = try await bridge.tabs(in: id)
        XCTAssertTrue(listed.isEmpty)
        do {
            try await bridge.closeTab(in: id, targetID: "owned-1")
            XCTFail("transferred tab closed")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_TARGET_NOT_OWNED") }
        do {
            try await bridge.activateTab(in: id, targetID: "owned-1")
            XCTFail("transferred tab activated")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_TARGET_NOT_OWNED") }
        _ = try await bridge.finish(id, keep: [])
        XCTAssertNotNil(model.tab(tabID))
        XCTAssertTrue(transport.closed.isEmpty)
    }

    func testStopDuringCreateCannotRegisterANewTarget() async throws {
        let (_, bridge, transport, id) = setup()
        transport.onCreate = { bridge.stop() }
        do {
            _ = try await bridge.createTab(in: id, url: "https://one.test")
            XCTFail("stopped bridge accepted target")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_SPACE_INACTIVE") }
        XCTAssertEqual(transport.closed, ["owned-1"])
    }

    func testCancelledCreationNeverDispatchesAndReleasesBudget() async throws {
        let (_, bridge, transport, id) = setup()
        let creation = Task { @MainActor in
            try await bridge.createTab(in: id, url: "https://cancelled.test")
        }
        creation.cancel()
        do {
            _ = try await creation.value
            XCTFail("Cancelled creation succeeded")
        } catch is CancellationError {
            XCTAssertTrue(transport.live.isEmpty)
        }
        _ = try await bridge.createTab(in: id, url: "https://next.test")
        XCTAssertEqual(transport.live.count, 1)
    }

    func testTakeoverDuringFinishPreservesRemainingPages() async throws {
        let (model, bridge, transport, id) = setup()
        _ = try await bridge.createTab(in: id, url: "https://one.test")
        _ = try await bridge.createTab(in: id, url: "https://two.test")
        transport.onClose = { model.takeOverWorkspace(id) }
        do {
            _ = try await bridge.finish(id, keep: [])
            XCTFail("continued after takeover")
        } catch let error as AgentBridgeError { XCTAssertEqual(error.code, "PEEKR_SPACE_USER_IN_CONTROL") }
        XCTAssertEqual(transport.closed, ["owned-1"])
        XCTAssertEqual(transport.live.count, 1)
    }
}

@MainActor
private final class FakeTargetTransport: AgentTargetTransport {
    var live: [[String: Any]] = []
    var closed: [String] = []
    var onCreate: (() -> Void)?
    var onClose: (() async -> Void)?
    private var counter = 0
    func targets() async throws -> [[String: Any]] { live }
    func command(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if method == "Target.createTarget" {
            counter += 1
            let id = "owned-\(counter)"
            live.append(["id": id, "type": "page", "url": params["url"] as? String ?? ""])
            onCreate?()
            return ["targetId": id]
        }
        if method == "Target.closeTarget", let id = params["targetId"] as? String {
            await onClose?()
            closed.append(id)
            live.removeAll { $0["id"] as? String == id }
            return ["success": true]
        }
        return [:]
    }
}
