import AppKit
import Observation

/// Loads, caches and persists per-app icons. Favicons are fetched from Google's
/// favicon service and cached to disk; users can override with a custom image.
@MainActor
@Observable
final class IconStore {
    private var images: [UUID: NSImage] = [:]
    private let dir: URL

    init() {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("Peekr/icons", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
    }

    /// Reading this in a SwiftUI body registers observation, so tiles update
    /// the moment an icon finishes loading.
    func image(for app: WebApp) -> NSImage? { images[app.id] }

    func warm(_ apps: [WebApp]) {
        for app in apps { load(app) }
    }

    func load(_ app: WebApp) {
        if images[app.id] != nil { return }
        if let disk = NSImage(contentsOf: fileURL(app.id)) {
            images[app.id] = disk
            return
        }
        if !app.usesCustomIcon { fetchFavicon(app) }
    }

    /// Force a fresh favicon fetch (e.g. after the URL changes).
    func refreshFavicon(_ app: WebApp) {
        guard !app.usesCustomIcon else { return }
        fetchFavicon(app)
    }

    func setCustomIcon(_ app: WebApp, from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url),
              let data = image.pngData() else { return false }
        try? data.write(to: fileURL(app.id), options: .atomic)
        images[app.id] = image
        return true
    }

    func clearCustomIcon(_ app: WebApp) {
        try? FileManager.default.removeItem(at: fileURL(app.id))
        images[app.id] = nil
        fetchFavicon(app)
    }

    // MARK: - Private

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).png")
    }

    private func fetchFavicon(_ app: WebApp) {
        guard let host = app.host,
              let url = URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(host)")
        else { return }
        let id = app.id
        let dest = fileURL(id)
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), image.size.width > 1
            else { return }
            self?.images[id] = image
            try? data.write(to: dest, options: .atomic)
        }
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
