import AppKit
import Foundation

struct NewTabWallpaper: Identifiable, Hashable {
    let id: String
    let title: String
    let isDark: Bool

    var imageName: String { "\(id).webp" }
    var thumbnailName: String { "\(id)-thumb.webp" }
}

enum NewTabWallpaperCatalog {
    static let defaultID = "topographic-light"

    static let items = [
        NewTabWallpaper(id: defaultID, title: "Topographic", isDark: false),
        NewTabWallpaper(id: "monet-field", title: "Field", isDark: false),
        NewTabWallpaper(id: "monet-coast", title: "Coast", isDark: false),
        NewTabWallpaper(id: "shanshui-light", title: "Shanshui", isDark: false),
        NewTabWallpaper(id: "topographic-dark", title: "Nocturne", isDark: true),
        NewTabWallpaper(id: "monet-nocturne", title: "Lily Pond", isDark: true),
    ]

    static func item(id: String) -> NewTabWallpaper {
        items.first { $0.id == id } ?? items[0]
    }

    static func image(
        selectedID: String,
        usesCustom: Bool,
        customPath: String,
        thumbnail: Bool = false
    ) -> NSImage? {
        if usesCustom, !customPath.isEmpty, let image = NSImage(contentsOfFile: customPath) {
            return image
        }
        let wallpaper = item(id: selectedID)
        let name = thumbnail ? wallpaper.thumbnailName : wallpaper.imageName
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "NewTabWallpapers"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard wallpaper.id != defaultID else { return nil }
        return image(selectedID: defaultID, usesCustom: false, customPath: "", thumbnail: thumbnail)
    }
}

enum NewTabWallpaperStorage {
    static var customDirectory: URL {
        let directory = AppPaths.supportDirectory.appendingPathComponent("NewTabWallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func importImage(from source: URL) throws -> String {
        guard NSImage(contentsOf: source) != nil else { throw ImportError.invalidImage }
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let destination = customDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.path
    }

    static func removeCustomImage(atPath path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent() == customDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    enum ImportError: Error {
        case invalidImage
    }
}
