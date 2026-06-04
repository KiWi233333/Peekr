import Foundation

/// A node in the bookmark tree: a folder (has `children`) or a link (has a
/// `urlString`). Mirrors how browsers store bookmarks so an import keeps its
/// original folder structure.
struct BookmarkNode: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String?
    var children: [BookmarkNode]?

    var isFolder: Bool { children != nil }

    init(id: UUID = UUID(), title: String, urlString: String? = nil, children: [BookmarkNode]? = nil) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case id, title, urlString, children }

    // Tolerant decode so the schema can evolve without dropping the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        children = try c.decodeIfPresent([BookmarkNode].self, forKey: .children)
    }
}
