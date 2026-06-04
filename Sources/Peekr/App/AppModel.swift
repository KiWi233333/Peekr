import Foundation
import Observation

/// Observable source of truth for the workspaces, the active tab and pin state.
/// Tab operations act on the *active* workspace, so the rail, web area and
/// Preferences all stay in sync with whichever space is showing.
@MainActor
@Observable
final class AppModel {
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID
    var selectedID: WebApp.ID?
    var isPinned: Bool = false

    private let store: AppStore

    init(store: AppStore) {
        self.store = store
        let data = store.load()
        workspaces = data.workspaces
        activeWorkspaceID = data.activeWorkspaceID ?? data.workspaces.first?.id ?? UUID()
        selectedID = workspaces.first { $0.id == activeWorkspaceID }?.tabs.first?.id
    }

    // MARK: - Active workspace

    var activeWorkspace: Workspace { workspaces.first { $0.id == activeWorkspaceID } ?? workspaces[0] }

    /// Tabs of the active workspace — what the rail and web area bind to.
    var apps: [WebApp] { activeWorkspace.tabs }

    /// Every tab across all workspaces — used as an omnibox suggestion source.
    var allTabs: [WebApp] { workspaces.flatMap(\.tabs) }

    private var activeIndex: Int { workspaces.firstIndex { $0.id == activeWorkspaceID } ?? 0 }

    func select(_ id: WebApp.ID) { selectedID = id }

    // MARK: - Tabs (operate on the active workspace)

    @discardableResult
    func addApp(title: String, urlString: String) -> WebApp {
        let app = WebApp(title: title, urlString: urlString)
        workspaces[activeIndex].tabs.append(app)
        selectedID = app.id
        persist()
        return app
    }

    func update(_ app: WebApp) {
        guard let idx = workspaces[activeIndex].tabs.firstIndex(where: { $0.id == app.id }) else { return }
        workspaces[activeIndex].tabs[idx] = app
        persist()
    }

    /// Inline-rename a tab's label.
    func rename(_ id: WebApp.ID, to title: String) {
        guard let idx = workspaces[activeIndex].tabs.firstIndex(where: { $0.id == id }) else { return }
        workspaces[activeIndex].tabs[idx].title = title
        persist()
    }

    func removeApp(_ id: WebApp.ID) {
        workspaces[activeIndex].tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = workspaces[activeIndex].tabs.first?.id }
        persist()
    }

    /// Move the tab identified by `draggedID` to sit just before `targetID`.
    func move(_ draggedID: WebApp.ID, before targetID: WebApp.ID) {
        guard draggedID != targetID,
              let from = workspaces[activeIndex].tabs.firstIndex(where: { $0.id == draggedID })
        else { return }
        let item = workspaces[activeIndex].tabs.remove(at: from)
        if let to = workspaces[activeIndex].tabs.firstIndex(where: { $0.id == targetID }) {
            workspaces[activeIndex].tabs.insert(item, at: to)
        } else {
            workspaces[activeIndex].tabs.append(item)
        }
        persist()
    }

    /// Reorder from a List's drag offsets (no SwiftUI dependency here).
    func moveApps(fromOffsets source: IndexSet, toOffset destination: Int) {
        var tabs = workspaces[activeIndex].tabs
        let moving = source.sorted().map { tabs[$0] }
        for index in source.sorted(by: >) { tabs.remove(at: index) }
        let adjusted = destination - source.filter { $0 < destination }.count
        tabs.insert(contentsOf: moving, at: min(max(0, adjusted), tabs.count))
        workspaces[activeIndex].tabs = tabs
        persist()
    }

    // MARK: - Workspaces

    func selectWorkspace(_ id: UUID) {
        guard id != activeWorkspaceID, workspaces.contains(where: { $0.id == id }) else { return }
        activeWorkspaceID = id
        selectedID = activeWorkspace.tabs.first?.id
        persist()
    }

    @discardableResult
    func addWorkspace() -> Workspace {
        let workspace = Workspace()
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id
        selectedID = nil
        persist()
        return workspace
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].name = name
        persist()
    }

    /// Remove a workspace (never the last one — there's always at least one).
    func removeWorkspace(_ id: UUID) {
        guard workspaces.count > 1, let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces.remove(at: idx)
        if activeWorkspaceID == id {
            activeWorkspaceID = workspaces[0].id
            selectedID = activeWorkspace.tabs.first?.id
        }
        persist()
    }

    func persist() {
        store.save(WorkspacesData(workspaces: workspaces, activeWorkspaceID: activeWorkspaceID))
    }
}
