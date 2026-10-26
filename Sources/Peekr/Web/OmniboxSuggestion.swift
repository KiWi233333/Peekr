import Foundation

/// One row in the omnibox autocomplete dropdown.
struct OmniboxSuggestion: Identifiable, Hashable {
    enum Kind: String, Hashable { case search, openURL, tab, bookmark, history }
    enum Action: Hashable {
        case navigate
        case switchToTab(WebApp.ID)
    }

    let kind: Kind
    let primary: String
    let secondary: String?
    /// Passed verbatim to `WebViewManager.loadAddress` when chosen.
    let target: String
    var action: Action = .navigate

    init(
        kind: Kind,
        primary: String,
        secondary: String?,
        target: String,
        action: Action = .navigate
    ) {
        self.kind = kind
        self.primary = primary
        self.secondary = secondary
        self.target = target
        self.action = action
    }

    /// Stable across query refreshes so SwiftUI reuses unchanged rows (and their
    /// favicon requests) instead of tearing the entire dropdown down per keypress.
    var id: String {
        switch action {
        case .switchToTab(let id): return "tab|\(id.uuidString)"
        case .navigate: return "\(kind.rawValue)|\(target.lowercased())"
        }
    }
}

/// Builds omnibox suggestions Chrome-style: matching open tabs first, then
/// recent history, the current search / open action and other local matches,
/// plus the selected provider's search completions (async network).
enum OmniboxSuggestions {
    /// Instant, local suggestions for `query`.
    static func local(
        for query: String,
        tabs: [WebApp],
        bookmarks: [BookmarkNode],
        history: [HistoryEntry] = [],
        currentTabID: WebApp.ID? = nil,
        searchLabel: String
    ) -> [OmniboxSuggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        var out: [OmniboxSuggestion] = []

        // Chrome keeps the current page and other matching open tabs above the
        // search action. Preserve the model's tab order after the active tab so
        // repeated queries do not reshuffle the remaining candidates.
        let matchingTabs = tabs.enumerated()
            .filter { matches(lower, $0.element.alias, $0.element.title, $0.element.urlString) }
            .sorted { lhs, rhs in
                let lhsIsCurrent = lhs.element.id == currentTabID
                let rhsIsCurrent = rhs.element.id == currentTabID
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
                return lhs.offset < rhs.offset
            }
            .prefix(4)

        for tab in matchingTabs.map(\.element) {
            out.append(OmniboxSuggestion(
                kind: .tab,
                primary: tab.displayName,
                secondary: URL(string: tab.urlString)?.displayHost ?? tab.urlString,
                target: tab.urlString,
                action: .switchToTab(tab.id)))
        }

        // Recent pages take precedence over the provider search action. This
        // makes Enter open the first matching history entry, like Chrome,
        // instead of immediately searching the typed keyword.
        var historyHits = 0
        for entry in history where matches(lower, entry.title, entry.urlString) {
            out.append(OmniboxSuggestion(
                kind: .history,
                primary: entry.title.isEmpty ? entry.urlString : entry.title,
                secondary: URL(string: entry.urlString)?.displayHost ?? entry.urlString,
                target: entry.urlString))
            historyHits += 1
            if historyHits >= 4 { break }
        }

        // The typed action follows matching history. It remains the fallback
        // when there is no local page to open.
        let looksLikeURL = lower.hasPrefix("http") || (!q.contains(" ") && q.contains("."))
        out.append(looksLikeURL
            ? OmniboxSuggestion(kind: .openURL, primary: q, secondary: nil, target: q)
            : OmniboxSuggestion(kind: .search, primary: q, secondary: searchLabel, target: q))

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
        return suggestions.filter { suggestion in
            switch suggestion.action {
            case .switchToTab:
                return seen.insert("tab|\(suggestion.target.lowercased())").inserted
            case .navigate:
                return seen.insert(suggestion.id).inserted
            }
        }
    }
}
