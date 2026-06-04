import Foundation

/// JSON persistence for the bookmark tree under Application Support/Peekr.
struct BookmarkStore {
    let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory.appendingPathComponent("bookmarks.json")
    }

    func load() -> [BookmarkNode] {
        guard let data = try? Data(contentsOf: fileURL),
              let nodes = try? JSONDecoder().decode([BookmarkNode].self, from: data) else { return [] }
        return nodes
    }

    func save(_ nodes: [BookmarkNode]) {
        guard let data = try? JSONEncoder().encode(nodes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
