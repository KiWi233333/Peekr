import Foundation

/// A single web app pinned into Peekr's dock.
struct WebApp: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String

    init(id: UUID = UUID(), title: String, urlString: String) {
        self.id = id
        self.title = title
        self.urlString = urlString
    }

    var url: URL? { URL(string: urlString) }

    var host: String? {
        url?.host?.replacingOccurrences(of: "www.", with: "")
    }

    /// First letter, used as a fallback tile glyph until favicons land.
    var monogram: String {
        let source = title.isEmpty ? (host ?? "?") : title
        return String(source.first.map(String.init) ?? "?").uppercased()
    }
}
