import Foundation

/// A single web app pinned into Peekr's dock.
struct WebApp: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var urlString: String
    /// User-chosen label that overrides the page title in the UI. Empty means
    /// "use the title" — see `displayName`. Lets near-identical sites be told apart.
    var alias: String
    /// When true, the icon at icons/<id>.png is user-supplied and favicon
    /// auto-fetch is skipped.
    var usesCustomIcon: Bool
    /// Remembered panel size for this app, in points. `0` means "inherit" — the
    /// panel falls back to the global default, then the screen-ratio default.
    /// See `PanelGeometry.resolveSize`.
    var panelWidth: Double
    var panelHeight: Double

    init(id: UUID = UUID(), title: String, urlString: String, alias: String = "",
         usesCustomIcon: Bool = false, panelWidth: Double = 0, panelHeight: Double = 0) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.alias = alias
        self.usesCustomIcon = usesCustomIcon
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
    }

    // Tolerate older app lists that predate `alias` / `usesCustomIcon` / per-app size.
    private enum CodingKeys: String, CodingKey {
        case id, title, urlString, alias, usesCustomIcon, panelWidth, panelHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        urlString = try c.decode(String.self, forKey: .urlString)
        alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
        usesCustomIcon = try c.decodeIfPresent(Bool.self, forKey: .usesCustomIcon) ?? false
        panelWidth = try c.decodeIfPresent(Double.self, forKey: .panelWidth) ?? 0
        panelHeight = try c.decodeIfPresent(Double.self, forKey: .panelHeight) ?? 0
    }

    var url: URL? { URL(string: urlString) }

    var host: String? { url?.displayHost }

    /// The single source for "what to call this app": alias → title → host → URL.
    /// Every UI surface (rail, tiles, omnibox) reads this instead of re-deriving it.
    var displayName: String {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        if !trimmedAlias.isEmpty { return trimmedAlias }
        if !title.isEmpty { return title }
        return host ?? urlString
    }

    var monogram: String { String(displayName.first.map(String.init) ?? "?").uppercased() }
}
