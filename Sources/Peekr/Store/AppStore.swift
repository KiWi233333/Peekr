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
            let migrated = WorkspacesData(
                workspaces: decoded.workspaces,
                activeWorkspaceID: decoded.activeWorkspaceID
            )
            if decoded.schemaVersion != WorkspacesData.currentSchemaVersion {
                save(migrated)
            }
            return migrated
        }
        // Legacy format: a bare `[WebApp]` array → wrap into one workspace.
        if let legacy = try? JSONDecoder().decode([WebApp].self, from: data), !legacy.isEmpty {
            let migrated = WorkspacesData(workspaces: [Workspace(tabs: legacy)])
            save(migrated)
            return migrated
        }
        return fallback
    }

    func save(_ data: WorkspacesData) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Keep the model usable; the next persistence attempt retries.
        }
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
