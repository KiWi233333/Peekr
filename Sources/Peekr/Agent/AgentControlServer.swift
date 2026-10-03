import Foundation
import Network

/// Loopback HTTP bridge that maps Peekr's spaces (workspaces) and their
/// ownership onto a small JSON API for peekr-cli. Bound to 127.0.0.1 only and
/// guarded by a per-launch bearer token published in `agent.json`, because
/// the surface can move windows and close pages.
///
/// Routes (all require `Authorization: Bearer <token>`):
///   GET    /spaces                 list spaces
///   POST   /spaces                 create an agent space {name, owner?}
///   GET    /spaces/:id             read one space
///   POST   /spaces/:id/claim       user|delegated → agent
///   POST   /spaces/:id/handoff     agent|delegated → delegated (stay ours)
///   POST   /spaces/:id/takeover    any → user
///   POST   /spaces/:id/complete    {keep:true} → keep for the user
///   DELETE /spaces/:id             close the space (removes its tabs)
@MainActor
final class AgentControlServer {
    private let model: AppModel
    private let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Peekr.AgentControlServer")
    private(set) var port: Int?
    var pages: AgentTargetSync?

    /// One request at a time is fine for a CLI harness; simplicity wins.
    init(model: AppModel, token: String) {
        self.model = model
        self.token = token
    }

    /// Start listening on an ephemeral loopback port; returns the bound port.
    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        // Register the continuation BEFORE starting, so a fast `.ready`
        // callback can never race past the await and hang the caller.
        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<Int>(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let bound = Int(listener.port?.rawValue ?? 0)
                    box.resume(returning: bound)
                case .failed(let error):
                    box.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in self.accept(connection) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private nonisolated func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                Task { @MainActor in
                    let response = await self.handle(request)
                    self.send(response, on: connection)
                }
            } else if error == nil, !isComplete {
                self.receiveRequest(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let body = Data(response.body.utf8)
        var head = "HTTP/1.1 \(response.status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let payload = Data(head.utf8) + body
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.header("Authorization") == "Bearer \(token)" else {
            return .json(status: "401 Unauthorized", payload: [
                "ok": false,
                "code": "PEEKR_AGENT_ACCESS_DISABLED",
                "message": "Missing or invalid bearer token; read agent.json.",
            ])
        }

        let segments = request.path.split(separator: "/").map(String.init)
        if segments.count >= 3, segments[0] == "spaces", segments[2] == "tabs" || segments[2] == "finish" {
            return await pageRoute(request, segments)
        }
        switch (request.method, segments.count) {
        case ("GET", 1) where segments[0] == "spaces":
            return .json(status: "200 OK", payload: ["ok": true, "spaces": model.workspaces.map(Self.spacePayload)])
        case ("POST", 1) where segments[0] == "spaces":
            let name = (request.jsonObject()?["name"] as? String) ?? ""
            let owner = (request.jsonObject()?["owner"] as? String) ?? ""
            let space = model.addAgentWorkspace(owner: owner, name: name)
            // CLI spaces start empty; UI-created tabs remain explicitly unmanaged.
            for tab in space.tabs { model.removeApp(tab.id) }
            let current = model.workspaces.first(where: { $0.id == space.id }) ?? space
            return .json(status: "201 Created", payload: ["ok": true, "space": Self.spacePayload(current)])
        case (_, 2) where segments[0] == "spaces":
            // /spaces/:id — read one space or close it (DELETE).
            return spaceRoute(request, segments[1], action: "")
        case (_, 3) where segments[0] == "spaces":
            // /spaces/:id/<action>
            return spaceRoute(request, segments[1], action: segments[2])
        default:
            return Self.error("404 Not Found", code: "PEEKR_ACTION_FAILED", message: "Unknown route \(request.method) \(request.path).")
        }
    }

    private func pageRoute(_ request: HTTPRequest, _ segments: [String]) async -> HTTPResponse {
        guard let id = UUID(uuidString: segments[1]), let pages else {
            return Self.error("409 Conflict", code: "PEEKR_BRIDGE_REQUIRED", message: "Native page bridge unavailable.")
        }
        do {
            let body = request.jsonObject() ?? [:]
            var result: [String: Any] = ["ok": true]
            switch (request.method, segments.count, segments[2]) {
            case ("GET", 3, "tabs"):
                result["tabs"] = try await pages.tabs(in: id)
            case ("POST", 3, "tabs"):
                result["tab"] = try await pages.createTab(in: id, url: body["url"] as? String ?? "")
            case ("DELETE", 4, "tabs"):
                try await pages.closeTab(in: id, targetID: segments[3])
            case ("POST", 5, "tabs") where segments[4] == "activate":
                try await pages.activateTab(in: id, targetID: segments[3])
            case ("POST", 3, "finish"):
                guard let keep = body["keep"] as? [String] else {
                    throw AgentBridgeError(code: "PEEKR_INVALID_ARGUMENT", message: "finish requires a keep target array.")
                }
                result["closed"] = try await pages.finish(id, keep: keep)
            default:
                return Self.error("404 Not Found", code: "PEEKR_ACTION_FAILED", message: "Unknown page route.")
            }
            return .json(status: "200 OK", payload: result)
        } catch let error as AgentBridgeError {
            return Self.error("409 Conflict", code: error.code, message: error.message)
        } catch {
            return Self.error("503 Service Unavailable", code: "PEEKR_CDP_UNAVAILABLE", message: "Target operation failed; result may be unknown. Do not replay automatically.")
        }
    }

    private func spaceRoute(_ request: HTTPRequest, _ rawID: String, action: String) -> HTTPResponse {
        guard let id = UUID(uuidString: rawID) else {
            return Self.error("400 Bad Request", code: "PEEKR_SPACE_NOT_FOUND", message: "Malformed space id.")
        }
        guard let workspace = model.workspaces.first(where: { $0.id == id }) else {
            return Self.error("404 Not Found", code: "PEEKR_SPACE_NOT_FOUND", message: "No space with id \(rawID).")
        }
        return handleSpaceAction(request.method, action, id, workspace, request)
    }

    private func handleSpaceAction(
        _ method: String,
        _ action: String,
        _ id: UUID,
        _ workspace: Workspace,
        _ request: HTTPRequest
    ) -> HTTPResponse {
        switch (method, action) {
        case ("GET", ""):
            return .json(status: "200 OK", payload: ["ok": true, "space": Self.spacePayload(workspace)])

        case ("POST", "claim"):
            let owner = request.jsonObject()?["owner"] as? String ?? ""
            guard let updated = model.claimWorkspace(id, agentName: owner) else {
                return Self.error("404 Not Found", code: "PEEKR_SPACE_NOT_FOUND", message: "No space with id \(id).")
            }
            return .json(status: "200 OK", payload: ["ok": true, "space": Self.spacePayload(updated)])

        case ("POST", "resume"):
            // Alias of claim for the ego-trained vocabulary; same transition.
            guard let updated = model.claimWorkspace(id) else {
                return Self.error("404 Not Found", code: "PEEKR_SPACE_NOT_FOUND", message: "No space with id \(id).")
            }
            return .json(status: "200 OK", payload: ["ok": true, "space": Self.spacePayload(updated)])

        case ("POST", "handoff"):
            guard workspace.isAgentOwned else {
                return Self.error("409 Conflict", code: "PEEKR_SPACE_USER_IN_CONTROL", message: "Only agent-owned spaces can be handed off.")
            }
            guard let updated = model.handOffWorkspace(id) else {
                return Self.error("404 Not Found", code: "PEEKR_SPACE_NOT_FOUND", message: "No space with id \(id).")
            }
            return .json(status: "200 OK", payload: ["ok": true, "space": Self.spacePayload(updated)])

        case ("POST", "takeover"):
            model.takeOverWorkspace(id)
            guard let updated = model.workspaces.first(where: { $0.id == id }) else {
                return Self.error("404 Not Found", code: "PEEKR_SPACE_NOT_FOUND", message: "No space with id \(id).")
            }
            return .json(status: "200 OK", payload: ["ok": true, "space": Self.spacePayload(updated)])

        case ("POST", "complete"):
            guard workspace.ownership == .agent else {
                return Self.error("409 Conflict", code: "PEEKR_SPACE_USER_IN_CONTROL", message: "The user controls this space.")
            }
            let keep = request.jsonObject()?["keep"] as? Bool ?? false
            guard keep || workspace.tabs.isEmpty else {
                return Self.error("409 Conflict", code: "PEEKR_TARGET_NOT_OWNED", message: "Use /finish to preserve unmanaged tabs.")
            }
            if !keep { model.removeWorkspace(id) }
            else { model.takeOverWorkspace(id) }
            return .json(status: "200 OK", payload: ["ok": true])

        case ("DELETE", ""):
            guard workspace.ownership == .agent, workspace.tabs.isEmpty else {
                return Self.error("409 Conflict", code: "PEEKR_TARGET_NOT_OWNED", message: "Only an empty agent space can be deleted; use /finish.")
            }
            let hadTabs = !workspace.tabs.isEmpty
            model.removeWorkspace(id)
            return .json(status: "200 OK", payload: ["ok": true, "closed": hadTabs])

        default:
            return Self.error("404 Not Found", code: "PEEKR_ACTION_FAILED", message: "Unknown space action \(method) /\(action).")
        }
    }

    static func spacePayload(_ workspace: Workspace) -> [String: Any] {
        var payload: [String: Any] = [
            "id": workspace.id.uuidString,
            "name": workspace.name,
            "ownership": workspace.ownership.rawValue,
            "agentOwner": workspace.agentOwner,
            "tabCount": workspace.tabs.count,
        ]
        if let selectedTabID = workspace.selectedTabID {
            payload["selectedTabID"] = selectedTabID.uuidString
        }
        return payload
    }

    private static func error(_ status: String, code: String, message: String) -> HTTPResponse {
        .json(status: status, payload: ["ok": false, "code": code, "message": message])
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    func jsonObject() -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// Parse a full request (head + Content-Length body) out of `data`, or nil
    /// when more bytes are needed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) ?? ""
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headEnd.upperBound...]
        guard body.count >= expected else { return nil }
        let path = URL(string: String(parts[1]))?.path ?? String(parts[1])
        return HTTPRequest(
            method: String(parts[0]),
            path: path,
            headers: headers,
            body: Data(body.prefix(expected))
        )
    }
}

private struct HTTPResponse {
    let status: String
    let body: String

    static func json(status: String, payload: [String: Any]) -> HTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return HTTPResponse(status: status, body: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    }
}

/// Bridges one continuation from callback-land into async; resumes exactly
/// once regardless of how many state callbacks fire.
private final class ContinuationBox<Value>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
