import Foundation
import Observation

/// Observable source of truth for the bookmark tree. Imports append a browser's
/// bookmarks as a new top-level folder, preserving their original structure.
@MainActor
@Observable
final class BookmarksModel {
    var roots: [BookmarkNode]

    private let store: BookmarkStore

    init(store: BookmarkStore) {
        self.store = store
        roots = store.load()
    }

    var isEmpty: Bool { roots.isEmpty }

    /// Append imported nodes under a new folder named after the browser.
    func importNodes(_ nodes: [BookmarkNode], as folderName: String) {
        guard !nodes.isEmpty else { return }
        roots.append(BookmarkNode(title: folderName, children: nodes))
        persist()
    }

    func remove(_ id: UUID) {
        roots = Self.removing(id, from: roots)
        persist()
    }

    /// Re-import each browser that was already imported (matched by its
    /// top-level folder name), refreshing that folder in place. Non-destructive:
    /// browsers never imported and manually-added nodes are left untouched.
    func syncFromBrowsers() {
        var changed = false
        for source in BookmarkImporter.availableSources() {
            guard let index = roots.firstIndex(where: { $0.title == source.name && $0.isFolder }) else { continue }
            let imported = BookmarkImporter.importBookmarks(from: source)
            guard !imported.isEmpty else { continue }
            roots[index] = BookmarkNode(id: roots[index].id, title: source.name, children: imported)
            changed = true
        }
        if changed { persist() }
    }

    func persist() { store.save(roots) }

    private static func removing(_ id: UUID, from nodes: [BookmarkNode]) -> [BookmarkNode] {
        nodes.compactMap { node in
            guard node.id != id else { return nil }
            guard let children = node.children else { return node }
            var copy = node
            copy.children = removing(id, from: children)
            return copy
        }
    }
}
