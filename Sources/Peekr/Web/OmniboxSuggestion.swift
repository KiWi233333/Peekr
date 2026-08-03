import Foundation

/// One row in the omnibox autocomplete dropdown.
struct OmniboxSuggestion: Identifiable, Hashable {
    enum Kind: Hashable { case search, openURL, tab, bookmark }
    let id = UUID()
    let kind: Kind
    let primary: String
    let secondary: String?
    /// Passed verbatim to `WebViewManager.loadAddress` when chosen.
    let target: String

    static func == (lhs: OmniboxSuggestion, rhs: OmniboxSuggestion) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Builds omnibox suggestions Chrome-style: a top "search / open" action, then
/// matching open tabs and bookmarks (instant, local), plus the selected
/// provider's search completions (async network).
enum OmniboxSuggestions {
    /// Instant, local suggestions for `query`.
    static func local(for query: String, tabs: [WebApp], bookmarks: [BookmarkNode], searchLabel: String) -> [OmniboxSuggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        var out: [OmniboxSuggestion] = []

        // Top action — mirrors WebViewManager.url(fromOmnibox:)'s intent.
        let looksLikeURL = lower.hasPrefix("http") || (!q.contains(" ") && q.contains("."))
        out.append(looksLikeURL
            ? OmniboxSuggestion(kind: .openURL, primary: q, secondary: nil, target: q)
            : OmniboxSuggestion(kind: .search, primary: q, secondary: searchLabel, target: q))

        // Matching open tabs (across workspaces).
        for tab in tabs where matches(lower, tab.alias, tab.title, tab.urlString) {
            out.append(OmniboxSuggestion(
                kind: .tab,
                primary: tab.displayName,
                secondary: URL(string: tab.urlString)?.displayHost ?? tab.urlString,
                target: tab.urlString))
            if out.count >= 4 { break }
        }

        // Matching bookmarks.
        var bookmarkHits = 0
        for node in flatten(bookmarks) {
            guard let url = node.urlString, matches(lower, node.title, url) else { continue }
            out.append(OmniboxSuggestion(
                kind: .bookmark,
                primary: node.title.isEmpty ? url : node.title,
                secondary: URL(string: url)?.displayHost ?? url,
                target: url))
            bookmarkHits += 1
            if bookmarkHits >= 3 { break }
        }

        return dedup(out)
    }

    /// Provider search-suggest completions (returns [] on any failure).
    static func searchCompletions(
        for query: String,
        using engine: SearchEngine = .google
    ) async -> [OmniboxSuggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let url = suggestionURL(for: q, using: engine),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let completions: [String]
        if let values = json as? [Any], values.count >= 2,
           let strings = values[1] as? [String] {
            completions = strings
        } else if let values = json as? [[String: Any]] {
            completions = values.compactMap { $0["phrase"] as? String }
        } else {
            return []
        }

        return completions.prefix(6).map {
            OmniboxSuggestion(kind: .search, primary: $0, secondary: nil, target: $0)
        }
    }

    // MARK: - Helpers

    private static func matches(_ lowerQuery: String, _ fields: String...) -> Bool {
        fields.contains { $0.lowercased().contains(lowerQuery) }
    }

    private static func suggestionURL(for query: String, using engine: SearchEngine) -> URL? {
        let endpoint: String
        let queryItems: [URLQueryItem]
        switch engine {
        case .google:
            endpoint = "https://suggestqueries.google.com/complete/search"
            queryItems = [
                URLQueryItem(name: "client", value: "firefox"),
                URLQueryItem(name: "q", value: query),
            ]
        case .bing:
            endpoint = "https://api.bing.com/osjson.aspx"
            queryItems = [URLQueryItem(name: "query", value: query)]
        case .duckDuckGo:
            endpoint = "https://duckduckgo.com/ac/"
            queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "list"),
            ]
        case .baidu:
            endpoint = "https://suggestion.baidu.com/su"
            queryItems = [
                URLQueryItem(name: "wd", value: query),
                URLQueryItem(name: "action", value: "opensearch"),
            ]
        }

        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = queryItems
        return components.url
    }

    private static func flatten(_ nodes: [BookmarkNode]) -> [BookmarkNode] {
        nodes.flatMap { node in node.children.map(flatten) ?? [node] }
    }

    private static func dedup(_ suggestions: [OmniboxSuggestion]) -> [OmniboxSuggestion] {
        var seen = Set<String>()
        return suggestions.filter { seen.insert("\($0.kind)|\($0.target.lowercased())").inserted }
    }
}
