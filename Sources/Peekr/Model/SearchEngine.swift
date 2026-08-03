import Foundation

/// Browser-wide search provider. The raw values are persisted, so keep them
/// stable when adding more providers in the future.
enum SearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case google
    case bing
    case duckDuckGo
    case baidu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        case .baidu: return "Baidu"
        }
    }

    var homepageURL: URL {
        switch self {
        case .google: return URL(string: "https://www.google.com/")!
        case .bing: return URL(string: "https://www.bing.com/")!
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/")!
        case .baidu: return URL(string: "https://www.baidu.com/")!
        }
    }

    func searchURL(for query: String) -> URL? {
        let endpoint: String
        let queryName: String
        switch self {
        case .google:
            endpoint = "https://www.google.com/search"
            queryName = "q"
        case .bing:
            endpoint = "https://www.bing.com/search"
            queryName = "q"
        case .duckDuckGo:
            endpoint = "https://duckduckgo.com/"
            queryName = "q"
        case .baidu:
            endpoint = "https://www.baidu.com/s"
            queryName = "wd"
        }

        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: queryName, value: query)]
        return components.url
    }
}
