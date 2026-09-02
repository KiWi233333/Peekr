import Foundation
import XCTest
@testable import Peekr

@MainActor
final class AgentControlServerTests: XCTestCase {
    private var model: AppModel!
    private var server: AgentControlServer!
    private var port = 0
    private let token = "test-token-123"

    override func setUp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-agent-server-\(UUID().uuidString).json")
        let store = AppStore(fileURL: url)
        store.save(WorkspacesData(workspaces: [Workspace(name: "Daily", tabs: [])]))
        model = AppModel(store: store)
        server = AgentControlServer(model: model, token: token)
        port = try await server.start()
        try XCTSkipIf(port == 0, "loopback listener unavailable in this environment")
        addTeardownBlock { [url] in try? FileManager.default.removeItem(at: url) }
    }

    override func tearDown() async throws {
        server.stop()
    }

    // MARK: - Helpers

    private func request(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        authorized: Bool = true
    ) async throws -> (status: Int, payload: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, payload)
    }

    private func space(_ payload: [String: Any]) -> [String: Any] {
        (payload["space"] as? [String: Any]) ?? [:]
    }

    // MARK: - Tests

    func testListSpacesMapsWorkspaceFields() async throws {
        let (status, payload) = try await request("GET", "/spaces")
        XCTAssertEqual(status, 200)
        let spaces = payload["spaces"] as? [[String: Any]] ?? []
        XCTAssertEqual(spaces.count, 1)
        XCTAssertEqual(spaces[0]["name"] as? String, "Daily")
        XCTAssertEqual(spaces[0]["ownership"] as? String, "user")
    }

    func testCreateAgentSpaceThenTakeoverThenClaim() async throws {
        var (status, payload) = try await request(
            "POST", "/spaces",
            body: ["name": "Scrape leads", "owner": "Claude Code"]
        )
        XCTAssertEqual(status, 201)
        let space = self.space(payload)
        let id = try XCTUnwrap(space["id"] as? String)
        XCTAssertEqual(space["ownership"] as? String, "agent")
        XCTAssertEqual(space["agentOwner"] as? String, "Claude Code")

        // User takes it over — one-way.
        (status, payload) = try await request("POST", "/spaces/\(id)/takeover")
        XCTAssertEqual(self.space(payload)["ownership"] as? String, "user")

        // The agent re-claims after the user confirms "continue".
        (status, payload) = try await request("POST", "/spaces/\(id)/claim", body: ["owner": "Claude Code"])
        XCTAssertEqual(self.space(payload)["ownership"] as? String, "agent")
    }

    func testHandOffMarksDelegatedAndStillAgentOwned() async throws {
        let (_, created) = try await request("POST", "/spaces", body: ["name": "login flow"])
        let id = try XCTUnwrap(self.space(created)["id"] as? String)

        let (_, handed) = try await request("POST", "/spaces/\(id)/handoff")
        XCTAssertEqual(self.space(handed)["ownership"] as? String, "agentDelegatedToUser")

        let (_, resumed) = try await request("POST", "/spaces/\(id)/resume")
        XCTAssertEqual(self.space(resumed)["ownership"] as? String, "agent")
    }

    func testHandOffOnUserSpaceIsRejectedWithStableCode() async throws {
        let (_, created) = try await request("POST", "/spaces", body: ["name": "temp"])
        let id = try XCTUnwrap(self.space(created)["id"] as? String)
        try await request("POST", "/spaces/\(id)/takeover")

        let (status, payload) = try await request("POST", "/spaces/\(id)/handoff")
        XCTAssertEqual(status, 409)
        XCTAssertEqual(payload["code"] as? String, "PEEKR_SPACE_USER_IN_CONTROL")
    }

    func testCompleteWithoutKeepClosesSpace() async throws {
        let (_, created) = try await request("POST", "/spaces", body: ["name": "one-shot"])
        let id = try XCTUnwrap(self.space(created)["id"] as? String)

        let (_, completed) = try await request("POST", "/spaces/\(id)/complete", body: ["keep": false])
        XCTAssertEqual(completed["ok"] as? Bool, true)
        let (_, listed) = try await request("GET", "/spaces")
        let ids = (listed["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertFalse(ids.contains(id))
    }

    func testCompleteWithKeepKeepsSpaceForTheUser() async throws {
        let (_, created) = try await request("POST", "/spaces", body: ["name": "show-off"])
        let id = try XCTUnwrap(self.space(created)["id"] as? String)

        let (_, completed) = try await request("POST", "/spaces/\(id)/complete", body: ["keep": true])
        XCTAssertEqual(completed["ok"] as? Bool, true)
        let (_, listed) = try await request("GET", "/spaces")
        let ids = (listed["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertTrue(ids.contains(id))
    }

    func testUnknownSpaceReturnsStableNotFoundCode() async throws {
        let random = UUID()
        let (status, payload) = try await request("GET", "/spaces/\(random.uuidString)")
        XCTAssertEqual(status, 404)
        XCTAssertEqual(payload["code"] as? String, "PEEKR_SPACE_NOT_FOUND")
    }

    func testRequestsWithoutTokenAreRejected() async throws {
        let (status, payload) = try await request("GET", "/spaces", authorized: false)
        XCTAssertEqual(status, 401)
        XCTAssertEqual(payload["code"] as? String, "PEEKR_AGENT_ACCESS_DISABLED")
    }
}
