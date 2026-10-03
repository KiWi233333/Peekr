import Foundation

struct AgentBridgeError: Error {
    let code: String
    let message: String
}

/// Browser transport used only for explicit target lifecycle commands. Never replays writes.
@MainActor
protocol AgentTargetTransport {
    func targets() async throws -> [[String: Any]]
    func command(_ method: String, _ params: [String: Any]) async throws -> [String: Any]
}

@MainActor
final class AgentCDPClient: AgentTargetTransport {
    let port: Int
    init(port: Int) { self.port = port }

    private func json(_ path: String) async throws -> Any {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentBridgeError(code: "PEEKR_CDP_UNAVAILABLE", message: "DevTools HTTP failed.")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func targets() async throws -> [[String: Any]] {
        guard let targets = try await json("/json/list") as? [[String: Any]] else {
            throw AgentBridgeError(code: "PEEKR_CDP_UNAVAILABLE", message: "Invalid target list.")
        }
        return targets.filter { ($0["type"] as? String) == "page" }
    }

    func command(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let version = try await json("/json/version") as? [String: Any],
            let raw = version["webSocketDebuggerUrl"] as? String,
            let url = URL(string: raw), url.scheme == "ws",
            url.host == "127.0.0.1" || url.host == "localhost"
        else {
            throw AgentBridgeError(code: "PEEKR_CDP_UNAVAILABLE", message: "Missing local browser socket.")
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            return try await receiveReply(socket, method: method)
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func receiveReply(_ socket: URLSessionWebSocketTask, method: String) async throws -> [String: Any] {
        while true {
            try Task.checkCancellation()
            let message = try await socket.receive()
            let bytes: Data
            switch message {
            case .data(let data): bytes = data
            case .string(let text): bytes = Data(text.utf8)
            @unknown default: continue
            }
            guard let reply = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                reply["id"] as? Int == 1
            else { continue }
            if let error = reply["error"] as? [String: Any] {
                throw AgentBridgeError(code: "PEEKR_ACTION_FAILED", message: error["message"] as? String ?? method)
            }
            return reply["result"] as? [String: Any] ?? [:]
        }
    }
}
