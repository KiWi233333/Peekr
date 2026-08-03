import Foundation

/// Persists the user's workspaces (each a named group of tabs) as JSON under
/// Application Support/Peekr. Transparently migrates the legacy flat `[WebApp]`
/// list into a single workspace so existing installs keep their tabs.
struct AppStore {
    let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory.appendingPathComponent("apps.json")
    }

    /// Inject a custom location (used by tests to avoid touching real user data).
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(fallback: WorkspacesData = Self.defaults()) -> WorkspacesData {
        guard let data = try? Data(contentsOf: fileURL) else { return fallback }
        // Current format: a workspaces object.
        if let decoded = try? JSONDecoder().decode(WorkspacesData.self, from: data),
           !decoded.workspaces.isEmpty {
            return decoded
        }
        // Legacy format: a bare `[WebApp]` array → wrap into one workspace.
        if let legacy = try? JSONDecoder().decode([WebApp].self, from: data), !legacy.isEmpty {
            return WorkspacesData(workspaces: [Workspace(tabs: legacy)])
        }
        return fallback
    }

    func save(_ data: WorkspacesData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    static func defaults(searchEngine: SearchEngine = .google) -> WorkspacesData {
        WorkspacesData(workspaces: [Workspace(tabs: [
            WebApp(
                title: searchEngine.displayName,
                urlString: searchEngine.homepageURL.absoluteString
            )
        ])])
    }
}
