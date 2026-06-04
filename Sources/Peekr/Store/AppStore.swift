import Foundation

/// Persists the user's workspaces (each a named group of tabs) as JSON under
/// Application Support/Peekr. Transparently migrates the legacy flat `[WebApp]`
/// list into a single workspace so existing installs keep their tabs.
struct AppStore {
    let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory.appendingPathComponent("apps.json")
    }

    func load() -> WorkspacesData {
        guard let data = try? Data(contentsOf: fileURL) else { return Self.defaults }
        // Current format: a workspaces object.
        if let decoded = try? JSONDecoder().decode(WorkspacesData.self, from: data),
           !decoded.workspaces.isEmpty {
            return decoded
        }
        // Legacy format: a bare `[WebApp]` array → wrap into one workspace.
        if let legacy = try? JSONDecoder().decode([WebApp].self, from: data), !legacy.isEmpty {
            return WorkspacesData(workspaces: [Workspace(tabs: legacy)])
        }
        return Self.defaults
    }

    func save(_ data: WorkspacesData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    static var defaults: WorkspacesData {
        WorkspacesData(workspaces: [Workspace(tabs: [
            WebApp(title: "ChatGPT", urlString: "https://chatgpt.com"),
            WebApp(title: "GitHub", urlString: "https://github.com"),
            WebApp(title: "YouTube", urlString: "https://youtube.com"),
            WebApp(title: "Gmail", urlString: "https://mail.google.com")
        ])])
    }
}
