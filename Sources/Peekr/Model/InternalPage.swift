import Foundation

/// One of Peekr's native browser pages. Chromium's `chrome://` pages are not
/// part of the embedded CEF's public surface, so Peekr serves its own
/// `peekr://` routes instead.
enum InternalPage: Hashable, Identifiable, Codable {
    case newTab
    case history
    case downloads
    case bookmarks
    case settings
    case siteSettings(String)
    case clearData
    case shortcuts

    static let scheme = "peekr"

    var id: String { urlString }

    var url: URL {
        switch self {
        case .newTab: return Self.constantURL("newtab")
        case .history: return Self.constantURL("history")
        case .downloads: return Self.constantURL("downloads")
        case .bookmarks: return Self.constantURL("bookmarks")
        case .settings: return Self.constantURL("settings")
        case .clearData: return Self.constantURL("clear-data")
        case .shortcuts: return Self.constantURL("shortcuts")
        case .siteSettings(let origin):
            guard !origin.isEmpty else { return Self.constantURL("site-settings") }
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "site-settings"
            components.queryItems = [URLQueryItem(name: "origin", value: origin)]
            return components.url ?? Self.constantURL("site-settings")
        }
    }

    var urlString: String { url.absoluteString }

    var omniboxEditingAddress: String {
        switch self {
        case .newTab: return ""
        default: return urlString
        }
    }

    static func from(_ url: URL) -> InternalPage? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host?.lowercased() else { return nil }
        switch host {
        case "newtab": return .newTab
        case "history": return .history
        case "downloads": return .downloads
        case "bookmarks": return .bookmarks
        case "settings": return .settings
        case "clear-data": return .clearData
        case "shortcuts": return .shortcuts
        case "site-settings":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let origin = components?.queryItems?.first(where: { $0.name == "origin" })?.value ?? ""
            return .siteSettings(origin)
        default:
            return nil
        }
    }

    static func isInternal(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let url = URL(string: raw), let page = Self.from(url) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown internal page URL: \(raw)"
            )
        }
        self = page
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(urlString)
    }

    private static func constantURL(_ host: String) -> URL {
        URL(string: "\(scheme)://\(host)")!
    }
}
