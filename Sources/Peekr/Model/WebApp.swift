import Foundation

/// A single web app pinned into Peekr's dock.
struct WebApp: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String
    /// When true, the icon at icons/<id>.png is user-supplied and favicon
    /// auto-fetch is skipped.
    var usesCustomIcon: Bool

    init(id: UUID = UUID(), title: String, urlString: String, usesCustomIcon: Bool = false) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.usesCustomIcon = usesCustomIcon
    }

    // Tolerate older app lists that predate `usesCustomIcon`.
    private enum CodingKeys: String, CodingKey {
        case id, title, urlString, usesCustomIcon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        urlString = try c.decode(String.self, forKey: .urlString)
        usesCustomIcon = try c.decodeIfPresent(Bool.self, forKey: .usesCustomIcon) ?? false
    }

    var url: URL? { URL(string: urlString) }

    var host: String? { url?.displayHost }

    var monogram: String {
        let source = title.isEmpty ? (host ?? "?") : title
        return String(source.first.map(String.init) ?? "?").uppercased()
    }
}
