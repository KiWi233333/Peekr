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

    func contains(urlString: String) -> Bool {
        Self.containsURL(urlString, in: roots)
    }

    func bookmark(for urlString: String) -> BookmarkNode? {
        Self.firstBookmark(matching: urlString, in: roots)
    }

    /// Bookmark the current page (⌘D). Saving an already-bookmarked URL is a
    /// no-op so the shortcut never creates duplicates.
    @discardableResult
    func add(title: String, urlString: String) -> Bool {
        add(title: title, urlString: urlString, toFolder: nil)
    }

    @discardableResult
    func add(title: String, urlString: String, toFolder folderID: UUID?) -> Bool {
        guard !urlString.isEmpty, !contains(urlString: urlString) else { return false }
        let node = BookmarkNode(title: title, urlString: urlString)
        guard let updated = Self.inserting(node, into: folderID, in: roots) else { return false }
        roots = updated
        persist()
        return true
    }

    func createFolder(name: String, in folderID: UUID?) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = BookmarkNode(title: trimmed, children: [])
        guard let updated = Self.inserting(folder, into: folderID, in: roots) else { return nil }
        roots = updated
        persist()
        return folder.id
    }

    func update(id: UUID, title: String?, urlString: String?) {
        guard title != nil || urlString != nil,
              let updated = Self.updating(id, title: title, urlString: urlString, in: roots)
        else { return }
        roots = updated
        persist()
    }

    func move(id: UUID, toFolder folderID: UUID?, at index: Int?) {
        if let folderID, folderID == id { return }
        guard let node = Self.node(id, in: roots) else { return }
        if let folderID, node.isFolder, Self.containsNode(folderID, in: node.children ?? []) {
            return
        }
        let extracted = Self.extracting(id, from: roots)
        guard let removed = extracted.removed,
              let updated = Self.inserting(removed, into: folderID, at: index, in: extracted.nodes)
        else { return }
        roots = updated
        persist()
    }

    /// Case-insensitive substring match over bookmark titles and URLs.
    func search(_ query: String) -> [BookmarkNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmarks = allBookmarks()
        guard !trimmed.isEmpty else { return bookmarks }
        return bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.urlString?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    func allBookmarks() -> [BookmarkNode] {
        Self.links(in: roots)
    }

    func exportHTML() -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file. -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        lines.append(contentsOf: Self.htmlLines(for: roots, depth: 1))
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
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
        roots = Self.extracting(id, from: roots).nodes
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

    private static func firstBookmark(matching urlString: String, in nodes: [BookmarkNode]) -> BookmarkNode? {
        for node in nodes {
            if node.urlString == urlString { return node }
            if let children = node.children,
               let found = firstBookmark(matching: urlString, in: children) {
                return found
            }
        }
        return nil
    }

    private static func node(_ id: UUID, in nodes: [BookmarkNode]) -> BookmarkNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children,
               let found = Self.node(id, in: children) {
                return found
            }
        }
        return nil
    }

    private static func containsNode(_ id: UUID, in nodes: [BookmarkNode]) -> Bool {
        nodes.contains { node in
            node.id == id || containsNode(id, in: node.children ?? [])
        }
    }

    private static func inserting(
        _ node: BookmarkNode,
        into folderID: UUID?,
        at index: Int? = nil,
        in nodes: [BookmarkNode]
    ) -> [BookmarkNode]? {
        guard let folderID else {
            var result = nodes
            result.insert(node, at: clamped(index, count: result.count))
            return result
        }
        for (position, candidate) in nodes.enumerated() {
            if candidate.id == folderID, candidate.isFolder {
                var folder = candidate
                var children = folder.children ?? []
                children.insert(node, at: clamped(index, count: children.count))
                folder.children = children
                var result = nodes
                result[position] = folder
                return result
            }
            if let children = candidate.children,
               let updated = inserting(node, into: folderID, at: index, in: children) {
                var folder = candidate
                folder.children = updated
                var result = nodes
                result[position] = folder
                return result
            }
        }
        return nil
    }

    private static func updating(
        _ id: UUID,
        title: String?,
        urlString: String?,
        in nodes: [BookmarkNode]
    ) -> [BookmarkNode]? {
        for (position, candidate) in nodes.enumerated() {
            if candidate.id == id {
                var node = candidate
                if let title { node.title = title }
                if let urlString { node.urlString = urlString }
                var result = nodes
                result[position] = node
                return result
            }
            if let children = candidate.children,
               let updated = updating(id, title: title, urlString: urlString, in: children) {
                var node = candidate
                node.children = updated
                var result = nodes
                result[position] = node
                return result
            }
        }
        return nil
    }

    private static func extracting(
        _ id: UUID,
        from nodes: [BookmarkNode]
    ) -> (nodes: [BookmarkNode], removed: BookmarkNode?) {
        var result: [BookmarkNode] = []
        var removed: BookmarkNode?
        for node in nodes {
            if node.id == id {
                removed = node
                continue
            }
            if let children = node.children {
                let extracted = extracting(id, from: children)
                if let found = extracted.removed { removed = found }
                var copy = node
                copy.children = extracted.nodes
                result.append(copy)
            } else {
                result.append(node)
            }
        }
        return (result, removed)
    }

    private static func links(in nodes: [BookmarkNode]) -> [BookmarkNode] {
        nodes.flatMap { node -> [BookmarkNode] in
            var result: [BookmarkNode] = []
            if let urlString = node.urlString, !urlString.isEmpty {
                result.append(node)
            }
            result.append(contentsOf: links(in: node.children ?? []))
            return result
        }
    }

    private static func htmlLines(for nodes: [BookmarkNode], depth: Int) -> [String] {
        let indent = String(repeating: "    ", count: depth)
        return nodes.flatMap { node -> [String] in
            if node.isFolder {
                var lines = [
                    "\(indent)<DT><H3>\(escapeHTML(node.title))</H3>",
                    "\(indent)<DL><p>",
                ]
                lines.append(contentsOf: htmlLines(for: node.children ?? [], depth: depth + 1))
                lines.append("\(indent)</DL><p>")
                return lines
            }
            guard let urlString = node.urlString, !urlString.isEmpty else { return [] }
            let title = node.title.isEmpty ? urlString : node.title
            return ["\(indent)<DT><A HREF=\"\(escapeHTML(urlString))\">\(escapeHTML(title))</A>"]
        }
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func clamped(_ index: Int?, count: Int) -> Int {
        guard let index else { return count }
        return min(max(index, 0), count)
    }

    private static func containsURL(_ urlString: String, in nodes: [BookmarkNode]) -> Bool {
        nodes.contains { node in
            node.urlString == urlString || containsURL(urlString, in: node.children ?? [])
        }
    }
}

extension BookmarkStore {
    init(fileURL: URL) { self.fileURL = fileURL }
}
