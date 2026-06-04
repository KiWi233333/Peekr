import Foundation

/// Persists the user's web-app list as JSON under Application Support/Peekr.
struct AppStore {
    let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("Peekr", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("apps.json")
    }

    func load() -> [WebApp] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let apps = try? JSONDecoder().decode([WebApp].self, from: data),
            !apps.isEmpty
        else {
            return Self.defaults
        }
        return apps
    }

    func save(_ apps: [WebApp]) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static let defaults: [WebApp] = [
        WebApp(title: "ChatGPT", urlString: "https://chatgpt.com"),
        WebApp(title: "GitHub", urlString: "https://github.com"),
        WebApp(title: "YouTube", urlString: "https://youtube.com"),
        WebApp(title: "Gmail", urlString: "https://mail.google.com")
    ]
}
