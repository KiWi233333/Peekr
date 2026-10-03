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

    /// Bookmark the current page (⌘D). Saving an already-bookmarked URL is a
    /// no-op so the shortcut never creates duplicates.
    @discardableResult
    func add(title: String, urlString: String) -> Bool {
        guard !urlString.isEmpty, !Self.containsURL(urlString, in: roots) else { return false }
        roots.append(BookmarkNode(title: title, urlString: urlString))
        persist()
        return true
    }

    /// Append imported nodes under a new folder named after the browser.
    func importNodes(_ nodes: [BookmarkNode], as folderName: String) {
        guard !nodes.isEmpty else { return }
        roots.append(BookmarkNode(title: folderName, children: nodes))
        persist()
    }

    /// Import a browser source idempotently. A repeated import refreshes the
    /// existing top-level browser folder instead of appending duplicates.
    func importOrRefreshNodes(_ nodes: [BookmarkNode], as folderName: String) {
        guard !nodes.isEmpty else { return }
        roots = Self.replacingImportedFolder(
            in: roots,
            folderName: folderName,
            with: nodes
        )
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

    static func replacingImportedFolder(
        in roots: [BookmarkNode],
        folderName: String,
        with nodes: [BookmarkNode]
    ) -> [BookmarkNode] {
        guard let index = roots.firstIndex(where: {
            $0.title == folderName && $0.isFolder
        }) else {
            return roots + [BookmarkNode(title: folderName, children: nodes)]
        }

        var result = roots
        result[index] = BookmarkNode(
            id: result[index].id,
            title: folderName,
            children: nodes
        )
        return result
    }

    private static func removing(_ id: UUID, from nodes: [BookmarkNode]) -> [BookmarkNode] {
        nodes.compactMap { node in
            guard node.id != id else { return nil }
            guard let children = node.children else { return node }
            var copy = node
            copy.children = removing(id, from: children)
            return copy
        }
    }

    private static func containsURL(_ urlString: String, in nodes: [BookmarkNode]) -> Bool {
        nodes.contains { node in
            node.urlString == urlString || containsURL(urlString, in: node.children ?? [])
        }
    }
}
