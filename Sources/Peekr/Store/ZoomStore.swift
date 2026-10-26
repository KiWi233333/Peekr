import Foundation

/// Persists Chrome-style per-site zoom levels. CEF stores a zoom level as a
/// small integer step; keeping it outside the tab record makes the preference
/// follow the site when the same origin is opened in another tab.
struct ZoomStore {
    private static let defaultKey = "__default__"

    private let fileURL: URL
    private var levels: [String: Double]
    private(set) var defaultLevel: Double

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("zoom.json")) {
        self.fileURL = fileURL
        let decoded = (try? JSONDecoder().decode(
            [String: Double].self,
            from: Data(contentsOf: fileURL)
        )) ?? [:]
        defaultLevel = ZoomLevelBounds.clamp(decoded[Self.defaultKey] ?? 0)
        levels = decoded.filter { $0.key != Self.defaultKey }
    }

    func level(for origin: String) -> Double { levels[origin] ?? defaultLevel }

    mutating func set(_ level: Double, for origin: String) {
        levels[origin] = Self.clamped(level)
        save()
    }

    mutating func reset(for origin: String) {
        levels.removeValue(forKey: origin)
        save()
    }

    mutating func setDefault(_ level: Double) {
        defaultLevel = Self.clamped(level)
        save()
    }

    mutating func clear() {
        levels.removeAll()
        defaultLevel = 0
        save()
    }

    private static func clamped(_ level: Double) -> Double {
        ZoomLevelBounds.clamp(level.rounded())
    }

    private func save() {
        var payload = levels
        if defaultLevel != 0 {
            payload[Self.defaultKey] = defaultLevel
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
