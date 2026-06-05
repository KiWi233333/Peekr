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

    /// Called when a tab is removed, so the composition root can tear down its
    /// cached web engine (and badge). Keeps the model free of any web reference.
    var onRemove: ((WebApp.ID) -> Void)?

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
    func addApp(title: String, urlString: String, alias: String = "") -> WebApp {
        let app = WebApp(title: title, urlString: urlString, alias: alias)
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

    /// Remember the panel size the user dragged this tab to, so activating it
    /// later restores that size. `0` for an axis means "inherit the default".
    func setPanelSize(_ id: WebApp.ID, width: Double, height: Double) {
        guard let idx = workspaces[activeIndex].tabs.firstIndex(where: { $0.id == id }) else { return }
        workspaces[activeIndex].tabs[idx].panelWidth = width
        workspaces[activeIndex].tabs[idx].panelHeight = height
        persist()
    }

    /// Set the user-facing alias — the single write path the rail's inline rename
    /// and the edit sheet both use. Empty clears it, so `displayName` falls back
    /// to the page title.
    func setAlias(_ id: WebApp.ID, to alias: String) {
        guard let idx = workspaces[activeIndex].tabs.firstIndex(where: { $0.id == id }) else { return }
        workspaces[activeIndex].tabs[idx].alias = alias
        persist()
    }

    /// Set the page title. The favicon-refresh path writes the freshly-fetched
    /// title here; the rail's inline rename writes the alias (`setAlias`) instead.
    func rename(_ id: WebApp.ID, to title: String) {
        guard let idx = workspaces[activeIndex].tabs.firstIndex(where: { $0.id == id }) else { return }
        workspaces[activeIndex].tabs[idx].title = title
        persist()
    }

    /// Mirror the engine's live `document.title` onto the tab as it navigates, so
    /// the rail name tracks the current page like a real browser tab. Searches all
    /// workspaces because engines outlive workspace switches; strips the unread
    /// token so it never duplicates the red badge; and coalesces the disk write —
    /// a busy page flips its title several times a second, but the rail updates
    /// in-memory instantly while only one JSON write lands after it settles.
    func applyLiveTitle(_ id: WebApp.ID, to rawTitle: String) {
        let title = BadgeParser.strippingCount(fromTitle: rawTitle)
        guard !title.isEmpty, let (w, t) = locate(id),
              workspaces[w].tabs[t].title != title else { return }
        workspaces[w].tabs[t].title = title
        schedulePersist()
    }

    private func locate(_ id: WebApp.ID) -> (workspace: Int, tab: Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let t = workspace.tabs.firstIndex(where: { $0.id == id }) { return (w, t) }
        }
        return nil
    }

    func removeApp(_ id: WebApp.ID) {
        workspaces[activeIndex].tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = workspaces[activeIndex].tabs.first?.id }
        persist()
        onRemove?(id)
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
        pendingPersist?.cancel()
        store.save(WorkspacesData(workspaces: workspaces, activeWorkspaceID: activeWorkspaceID))
    }

    /// Debounce for the high-frequency live-title path: collapse a burst of title
    /// changes into a single write ~1s after the last one. Any immediate `persist()`
    /// supersedes a pending one (it cancels the timer), so state never lags.
    private var pendingPersist: Task<Void, Never>?

    private func schedulePersist() {
        pendingPersist?.cancel()
        pendingPersist = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }
}
