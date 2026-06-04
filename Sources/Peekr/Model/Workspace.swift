import Foundation

/// A named group of tabs — Peekr's "space". The left sidebar shows the active
/// workspace's tabs; switching workspaces swaps the whole set. An empty `name`
/// is rendered as a localized default, so the stored value stays language-free.
struct Workspace: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var tabs: [WebApp]

    init(id: UUID = UUID(), name: String = "", symbol: String = "square.stack", tabs: [WebApp] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey { case id, name, symbol, tabs }

    // Tolerant decode so the schema can evolve without dropping the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.stack"
        tabs = try c.decodeIfPresent([WebApp].self, forKey: .tabs) ?? []
    }
}

/// Persisted shape of the whole dock: the workspaces plus which one is active.
struct WorkspacesData: Codable {
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID?

    init(workspaces: [Workspace], activeWorkspaceID: UUID? = nil) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
    }

    private enum CodingKeys: String, CodingKey { case workspaces, activeWorkspaceID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        activeWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID) ?? nil
    }
}
