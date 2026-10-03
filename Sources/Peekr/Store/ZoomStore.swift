import Foundation

/// Persists Chrome-style per-site zoom levels. CEF stores a zoom level as a
/// small integer step; keeping it outside the tab record makes the preference
/// follow the site when the same origin is opened in another tab.
struct ZoomStore {
    private let fileURL: URL
    private var levels: [String: Double]

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("zoom.json")) {
        self.fileURL = fileURL
        levels = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    func level(for origin: String) -> Double { levels[origin] ?? 0 }

    mutating func set(_ level: Double, for origin: String) {
        let clamped = min(max(level.rounded(), -5), 5)
        if clamped == 0 {
            levels.removeValue(forKey: origin)
        } else {
            levels[origin] = clamped
        }
        save()
    }

    mutating func reset(for origin: String) {
        levels.removeValue(forKey: origin)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(levels) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
