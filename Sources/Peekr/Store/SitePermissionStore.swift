import Foundation
import Observation

/// Per-site permission decisions remembered across launches. CEF's synchronous
/// permission delegate consults this store before building a native prompt.
@Observable
final class SitePermissionStore {
    enum Permission: String, Codable, CaseIterable, Identifiable {
        case camera, microphone, geolocation, notifications, clipboard, midi
        case pointerLock, storageAccess, sensors, windowManagement, downloads, other
        var id: String { rawValue }
    }

    static let shared = SitePermissionStore(
        fileURL: AppPaths.supportDirectory.appendingPathComponent("permissions.json")
    )

    private let fileURL: URL?
    private var stored: [String: [String: Bool]]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data)
        else {
            stored = [:]
            return
        }
        stored = decoded
    }

    var sites: [String: [Permission: Bool]] {
        var snapshot: [String: [Permission: Bool]] = [:]
        for origin in stored.keys.sorted() {
            guard let decisions = stored[origin] else { continue }
            var converted: [Permission: Bool] = [:]
            for (key, allowed) in decisions {
                if let permission = Permission(rawValue: key) {
                    converted[permission] = allowed
                }
            }
            snapshot[origin] = converted
        }
        return snapshot
    }

    var isEmpty: Bool { stored.isEmpty }

    func decision(origin: String, permission: Permission) -> Bool? {
        stored[Self.normalize(origin)]?[permission.rawValue]
    }

    func remember(origin: String, permission: Permission, allowed: Bool) {
        remember(origin: origin, permissions: [permission], allowed: allowed)
    }

    func remember(origin: String, permissions: [Permission], allowed: Bool) {
        let key = Self.normalize(origin)
        guard !key.isEmpty, !permissions.isEmpty else { return }
        var decisions = stored[key] ?? [:]
        for permission in permissions {
            decisions[permission.rawValue] = allowed
        }
        stored[key] = decisions
        persist()
    }

    func forget(origin: String, permission: Permission) {
        let key = Self.normalize(origin)
        guard var decisions = stored[key],
              decisions.removeValue(forKey: permission.rawValue) != nil else { return }
        if decisions.isEmpty {
            stored.removeValue(forKey: key)
        } else {
            stored[key] = decisions
        }
        persist()
    }

    func forget(origin: String) {
        guard stored.removeValue(forKey: Self.normalize(origin)) != nil else { return }
        persist()
    }

    func forgetAll() {
        guard !stored.isEmpty else { return }
        stored.removeAll()
        persist()
    }

    static func normalize(_ origin: String) -> String {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           let host = url.host?.lowercased(),
           !host.isEmpty {
            let port = url.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)"
        }
        var fallback = trimmed.lowercased()
        while fallback.hasSuffix("/") {
            fallback.removeLast()
        }
        return fallback
    }

    private func persist() {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
