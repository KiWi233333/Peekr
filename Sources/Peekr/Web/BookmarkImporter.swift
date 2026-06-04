import Foundation

/// Reads bookmarks straight from a browser's on-disk file (no automation), and
/// converts them into Peekr's `BookmarkNode` tree, preserving folder structure.
///
/// Chromium browsers (Chrome/Edge/Brave) store a plain-JSON `Bookmarks` file in
/// their profile — readable without any special permission. Safari keeps a
/// `Bookmarks.plist` in `~/Library/Safari`, which is TCC-protected; reading it
/// may fail unless Peekr has Full Disk Access, in which case it's skipped.
enum BookmarkImporter {
    struct Source: Identifiable {
        let id = UUID()
        let name: String
        let fileURL: URL
        let isSafari: Bool
    }

    /// Browser bookmark files that actually exist on this machine.
    static func availableSources() -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support")
        let candidates: [(name: String, url: URL, safari: Bool)] = [
            ("Chrome", appSupport.appendingPathComponent("Google/Chrome/Default/Bookmarks"), false),
            ("Edge", appSupport.appendingPathComponent("Microsoft Edge/Default/Bookmarks"), false),
            ("Brave", appSupport.appendingPathComponent("BraveSoftware/Brave-Browser/Default/Bookmarks"), false),
            ("Safari", home.appendingPathComponent("Library/Safari/Bookmarks.plist"), true),
        ]
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .map { Source(name: $0.name, fileURL: $0.url, isSafari: $0.safari) }
    }

    /// Parse a source into top-level bookmark nodes (folders + links).
    static func importBookmarks(from source: Source) -> [BookmarkNode] {
        source.isSafari ? safariBookmarks(source.fileURL) : chromiumBookmarks(source.fileURL)
    }

    // MARK: - Chromium ( { roots: { bookmark_bar: {…}, other: {…} } } )

    private static func chromiumBookmarks(_ url: URL) -> [BookmarkNode] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = obj["roots"] as? [String: Any] else { return [] }
        return ["bookmark_bar", "other", "synced"]
            .compactMap { roots[$0] as? [String: Any] }
            .compactMap(chromiumNode)
            .filter { ($0.children?.isEmpty == false) }
    }

    private static func chromiumNode(_ dict: [String: Any]) -> BookmarkNode? {
        let name = dict["name"] as? String ?? ""
        if let urlStr = dict["url"] as? String {
            return BookmarkNode(title: name.isEmpty ? urlStr : name, urlString: urlStr)
        }
        let children = (dict["children"] as? [[String: Any]] ?? []).compactMap(chromiumNode)
        return BookmarkNode(title: name, children: children)
    }

    // MARK: - Safari ( nested WebBookmarkType lists/leaves )

    private static func safariBookmarks(_ url: URL) -> [BookmarkNode] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return (plist["Children"] as? [[String: Any]])?.compactMap(safariNode) ?? []
    }

    private static func safariNode(_ dict: [String: Any]) -> BookmarkNode? {
        switch dict["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            guard let urlStr = dict["URLString"] as? String else { return nil }
            let title = (dict["URIDictionary"] as? [String: Any])?["title"] as? String
            return BookmarkNode(title: title ?? urlStr, urlString: urlStr)
        case "WebBookmarkTypeList":
            let title = dict["Title"] as? String ?? ""
            let children = (dict["Children"] as? [[String: Any]])?.compactMap(safariNode) ?? []
            return BookmarkNode(title: title, children: children)
        default:
            return nil // proxies, reading-list, etc.
        }
    }
}
