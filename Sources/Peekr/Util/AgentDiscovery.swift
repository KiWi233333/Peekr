import Foundation

/// Well-known discovery file external agent tooling reads to find Peekr's
/// DevTools endpoint without port scanning: `agent.json` under Application
/// Support, holding the localhost CDP port and the owning process. Written at
/// launch when agent access is enabled, removed otherwise, so its existence
/// itself signals "agent access is on".
enum AgentDiscovery {
    struct Discovery: Codable {
        var schemaVersion: Int
        var port: Int
        var pid: Int32
    }

    static let schemaVersion = 1

    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("agent.json")
    }

    /// Injectable file location — tests must not touch real user data.
    static func publish(port: Int, to fileURL: URL? = nil) {
        let target = fileURL ?? Self.fileURL
        let discovery = Discovery(
            schemaVersion: schemaVersion,
            port: port,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        guard let encoded = try? JSONEncoder().encode(discovery) else { return }
        try? encoded.write(to: target, options: .atomic)
    }

    static func revoke(at fileURL: URL? = nil) {
        try? FileManager.default.removeItem(at: fileURL ?? Self.fileURL)
    }
}
