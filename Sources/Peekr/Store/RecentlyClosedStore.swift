import Foundation

/// A tab that left the model, with the position needed to put it back.
struct ClosedTab: Codable, Equatable {
    let app: WebApp
    let workspaceID: UUID
    let groupID: UUID?
    let topLevelIndex: Int
    let childIndex: Int?
}

/// Persists the recently closed tab stack as JSON under
/// Application Support/Peekr. Private-space tabs never reach this store.
struct RecentlyClosedStore {
    static let capacity = 25

    private let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("recently-closed.json")) {
        self.fileURL = fileURL
    }

    func load() -> [ClosedTab] {
        guard let data = try? Data(contentsOf: fileURL),
              let tabs = try? JSONDecoder().decode([ClosedTab].self, from: data) else {
            return []
        }
        return Array(tabs.suffix(Self.capacity))
    }

    func save(_ tabs: [ClosedTab]) {
        let capped = Array(tabs.suffix(Self.capacity))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
