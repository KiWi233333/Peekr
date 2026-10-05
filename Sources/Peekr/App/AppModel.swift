import Foundation
import Observation

/// Observable browser model: Arc-like Spaces containing an ordered mix of
/// ungrouped tabs and Edge-like collapsible tab groups.
@MainActor
@Observable
final class AppModel {
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID
    var profiles: [BrowserProfile]
    var isPinned: Bool = false

    /// Called after a tab record leaves the model, allowing the composition root
    /// to tear down its cached engine and badge without coupling this layer to UI.
    var onRemove: ((WebApp.ID) -> Void)?
    /// Called before the active Workspace changes so live engines can be
    /// closed before the model points the UI at another Profile/context.
    var onWorkspaceSwitch: ((Workspace.ID, Workspace.ID) -> Void)?
    /// Called before a Workspace changes Profile, while the old binding is
    /// still readable and its engines can be closed deterministically.
    var onWorkspaceProfileChange: ((Workspace.ID, BrowserProfile.ID, BrowserProfile.ID) -> Void)?

    private struct ClosedTab {
        let app: WebApp
        let workspaceID: Workspace.ID
        let groupID: TabGroup.ID?
        let topLevelIndex: Int
        let childIndex: Int?
    }

    /// A group made implicitly by dropping one loose tab onto another. It is
    /// deliberately runtime-only: relaunching the app is a strong enough
    /// boundary to treat every persisted group as intentional.
    private struct ProvisionalGroup {
        let createdAt: TimeInterval
    }

    private static let provisionalGroupLifetime: TimeInterval = 8

    private let store: AppStore
    private let profileStore: ProfileStore
    private let searchEngine: () -> SearchEngine
    private let provisionalNow: () -> TimeInterval
    private var recentlyClosed: [ClosedTab] = []
    private var selectionHistory: [WebApp.ID] = []
    private var provisionalGroups: [TabGroup.ID: ProvisionalGroup] = [:]
    private var pendingPersist: Task<Void, Never>?

    init(
        store: AppStore,
        profileStore: ProfileStore = ProfileStore(),
        searchEngine: @escaping () -> SearchEngine = { .google },
        provisionalNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.profileStore = profileStore
        self.searchEngine = searchEngine
        self.provisionalNow = provisionalNow
        let profileRegistry = profileStore.load()
        let availableProfiles = profileRegistry.profiles
        profiles = availableProfiles
        let data = store.load(fallback: AppStore.defaults(searchEngine: searchEngine()))
        var loadedWorkspaces = data.workspaces.isEmpty ? [Workspace()] : data.workspaces
        let knownProfileIDs = Set(availableProfiles.map(\.id))
        for index in loadedWorkspaces.indices where !knownProfileIDs.contains(loadedWorkspaces[index].profileID) {
            loadedWorkspaces[index].profileID = BrowserProfile.defaultID
        }
        let validActiveID = data.activeWorkspaceID.flatMap { id in
            loadedWorkspaces.contains { $0.id == id } ? id : nil
        }
        workspaces = loadedWorkspaces
        activeWorkspaceID = validActiveID ?? loadedWorkspaces[0].id
        for index in workspaces.indices { workspaces[index].normalizeSidebar() }
        normalizeWorkspaceOrder()
        if let selectedID { selectionHistory = [selectedID] }
    }

    // MARK: - Active space and ordering

    private var activeIndex: Int {
        workspaces.firstIndex { $0.id == activeWorkspaceID } ?? 0
    }

    var activeWorkspace: Workspace { workspaces[activeIndex] }

    /// The overview order is derived from the persisted order so pinned spaces
    /// remain together without losing the user's order inside either section.
    var orderedWorkspaces: [Workspace] {
        workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }

    /// Browser order for the active Space, including children of collapsed
    /// groups. Collapse is presentation-only and never changes shortcut order.
    var apps: [WebApp] {
        orderedApps(in: activeWorkspace)
    }

    var allTabs: [WebApp] { workspaces.flatMap(\.tabs) }

    var selectedID: WebApp.ID? {
        get { workspaces[activeIndex].selectedTabID }
        set { workspaces[activeIndex].selectedTabID = newValue }
    }

    var hasRecentlyClosedTabs: Bool { !recentlyClosed.isEmpty }

    func tab(_ id: WebApp.ID) -> WebApp? {
        guard let location = locate(id) else { return nil }
        return workspaces[location.workspace].tabs[location.tab]
    }

    func group(_ id: TabGroup.ID) -> TabGroup? {
        workspaces[activeIndex].groups.first { $0.id == id }
    }

    func group(containing tabID: WebApp.ID) -> TabGroup? {
        workspaces[activeIndex].group(containing: tabID)
    }

    func select(_ id: WebApp.ID) {
        guard workspaces[activeIndex].tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        recordSelection(id)
        persist()
    }

    @discardableResult
    func selectAdjacentTab(reverse: Bool = false) -> WebApp.ID? {
        let ids = activeWorkspace.orderedTabIDs
        guard !ids.isEmpty else { return nil }
        let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let delta = reverse ? -1 : 1
        let next = (current + delta + ids.count) % ids.count
        select(ids[next])
        return ids[next]
    }

    /// Selects a numbered tab using Chrome's shortcut convention: ⌘1–⌘8
    /// address the corresponding tab and ⌘9 always addresses the last tab.
    @discardableResult
    func selectShortcutTab(_ number: Int) -> WebApp.ID? {
        guard (1...9).contains(number) else { return nil }
        let ids = activeWorkspace.orderedTabIDs
        guard !ids.isEmpty else { return nil }
        let index = number == 9 ? ids.count - 1 : number - 1
        guard ids.indices.contains(index) else { return nil }
        select(ids[index])
        return ids[index]
    }

    @discardableResult
    func selectMostRecentTab() -> WebApp.ID? {
        guard let current = selectedID else { return selectAdjacentTab() }
        guard let recent = selectionHistory.first(where: { $0 != current && tab($0) != nil }) else {
            return selectAdjacentTab()
        }
        if let location = locate(recent), workspaces[location.workspace].id != activeWorkspaceID {
            selectWorkspace(workspaces[location.workspace].id)
        }
        select(recent)
        return recent
    }

    // MARK: - Tabs

    @discardableResult
    func addApp(
        title: String,
        urlString: String,
        alias: String = "",
        toGroup groupID: TabGroup.ID? = nil,
        select: Bool = true
    ) -> WebApp {
        let app = WebApp(title: title, urlString: urlString, alias: alias)
        workspaces[activeIndex].tabs.append(app)
        if let groupID, let groupIndex = activeGroupIndex(groupID) {
            workspaces[activeIndex].groups[groupIndex].tabIDs.append(app.id)
            workspaces[activeIndex].groups[groupIndex].isCollapsed = false
            if workspaces[activeIndex].groups[groupIndex].tabIDs.count >= 3 {
                confirmGroup(groupID)
            }
        } else {
            workspaces[activeIndex].sidebarItems.append(.tab(app.id))
        }
        if select {
            selectedID = app.id
            recordSelection(app.id)
        }
        persist()
        return app
    }

    @discardableResult
    func addBlankTab(toGroup groupID: TabGroup.ID? = nil) -> WebApp {
        let provider = searchEngine()
        return addApp(
            title: provider.displayName,
            urlString: provider.homepageURL.absoluteString,
            toGroup: groupID
        )
    }

    @discardableResult
    func duplicateTab(_ id: WebApp.ID) -> WebApp? {
        guard let source = tab(id) else { return nil }
        let copy = WebApp(title: source.title, urlString: source.urlString, alias: source.alias)
        workspaces[activeIndex].tabs.append(copy)
        if let group = group(containing: id), let groupIndex = activeGroupIndex(group.id) {
            let sourceIndex = workspaces[activeIndex].groups[groupIndex].tabIDs.firstIndex(of: id)
                ?? workspaces[activeIndex].groups[groupIndex].tabIDs.count - 1
            workspaces[activeIndex].groups[groupIndex].tabIDs.insert(
                copy.id,
                at: min(sourceIndex + 1, workspaces[activeIndex].groups[groupIndex].tabIDs.count)
            )
            workspaces[activeIndex].groups[groupIndex].isCollapsed = false
            if workspaces[activeIndex].groups[groupIndex].tabIDs.count >= 3 {
                confirmGroup(group.id)
            }
        } else {
            let sourceIndex = workspaces[activeIndex].sidebarItems.firstIndex {
                $0.kind == .tab && $0.referenceID == id
            } ?? workspaces[activeIndex].sidebarItems.count - 1
            workspaces[activeIndex].sidebarItems.insert(
                .tab(copy.id),
                at: min(sourceIndex + 1, workspaces[activeIndex].sidebarItems.count)
            )
        }
        selectedID = copy.id
        recordSelection(copy.id)
        persist()
        return copy
    }

    func update(_ app: WebApp) {
        guard let location = locate(app.id) else { return }
        workspaces[location.workspace].tabs[location.tab] = app
        persist()
    }

    func setAlias(_ id: WebApp.ID, to alias: String) {
        guard let location = locate(id) else { return }
        workspaces[location.workspace].tabs[location.tab].alias = alias
        persist()
    }

    /// Pins a tab at the top of its workspace rail. `Workspace.normalizeSidebar`
    /// moves pinned records out of groups and keeps the pinned order stable.
    func togglePin(_ id: WebApp.ID) {
        guard let location = locate(id) else { return }
        workspaces[location.workspace].tabs[location.tab].isPinned.toggle()
        persist()
    }

    func rename(_ id: WebApp.ID, to title: String) {
        guard let location = locate(id) else { return }
        workspaces[location.workspace].tabs[location.tab].title = title
        persist()
    }

    func applyLiveTitle(_ id: WebApp.ID, to rawTitle: String) {
        let title = BadgeParser.strippingCount(fromTitle: rawTitle)
        guard !title.isEmpty, let location = locate(id),
              workspaces[location.workspace].tabs[location.tab].title != title else { return }
        workspaces[location.workspace].tabs[location.tab].title = title
        schedulePersist()
    }

    /// Persists only settled navigation facts. Transient loading URLs never
    /// replace the last known recovery target.
    func applyLiveNavigation(_ id: WebApp.ID, url: URL?, title rawTitle: String) {
        guard let location = locate(id) else { return }
        var changed = false
        if let url, workspaces[location.workspace].tabs[location.tab].urlString != url.absoluteString {
            workspaces[location.workspace].tabs[location.tab].urlString = url.absoluteString
            changed = true
        }
        let title = BadgeParser.strippingCount(fromTitle: rawTitle)
        if !title.isEmpty, workspaces[location.workspace].tabs[location.tab].title != title {
            workspaces[location.workspace].tabs[location.tab].title = title
            changed = true
        }
        if changed { schedulePersist() }
    }

    func toggleKeepAwake(_ id: WebApp.ID) {
        guard let location = locate(id) else { return }
        workspaces[location.workspace].tabs[location.tab].keepAwake.toggle()
        persist()
    }

    func removeApp(_ id: WebApp.ID) {
        guard let location = locate(id) else { return }
        let workspaceIndex = location.workspace
        let workspace = workspaces[workspaceIndex]
        let ordered = workspace.orderedTabIDs
        let oldOrderIndex = ordered.firstIndex(of: id) ?? 0
        let group = workspace.group(containing: id)
        let topIndex = workspace.sidebarItems.firstIndex {
            $0.referenceID == (group?.id ?? id)
        } ?? workspace.sidebarItems.count
        let childIndex = group?.tabIDs.firstIndex(of: id)

        recentlyClosed.append(ClosedTab(
            app: workspace.tabs[location.tab],
            workspaceID: workspace.id,
            groupID: group?.id,
            topLevelIndex: topIndex,
            childIndex: childIndex
        ))
        if recentlyClosed.count > 25 { recentlyClosed.removeFirst(recentlyClosed.count - 25) }

        removeTabReference(id, from: workspaceIndex, pruneEmptyGroups: true)
        workspaces[workspaceIndex].tabs.removeAll { $0.id == id }
        selectionHistory.removeAll { $0 == id }

        if workspaces[workspaceIndex].selectedTabID == id {
            let remaining = workspaces[workspaceIndex].orderedTabIDs
            workspaces[workspaceIndex].selectedTabID = remaining.isEmpty
                ? nil
                : remaining[min(oldOrderIndex, remaining.count - 1)]
            if workspaceIndex == activeIndex, let selectedID { recordSelection(selectedID) }
        }
        persist()
        onRemove?(id)
    }

    /// Chrome-style bulk tab actions. The context-menu tab stays open and is
    /// selected after the operation, so closing background tabs never leaves
    /// the browser pointing at a fallback tab by accident.
    func closeOtherTabs(keeping keepID: WebApp.ID) {
        guard activeWorkspace.orderedTabIDs.contains(keepID) else { return }
        let ids = activeWorkspace.orderedTabIDs.filter { $0 != keepID }
        for id in ids { removeApp(id) }
        if tab(keepID) != nil { select(keepID) }
    }

    func closeTabsToRight(of anchorID: WebApp.ID) {
        let ids = activeWorkspace.orderedTabIDs
        guard let anchorIndex = ids.firstIndex(of: anchorID) else { return }
        for id in ids.dropFirst(anchorIndex + 1) { removeApp(id) }
        if tab(anchorID) != nil { select(anchorID) }
    }

    @discardableResult
    func reopenLastClosedTab() -> WebApp? {
        guard let closed = recentlyClosed.popLast() else { return nil }
        let workspaceIndex = workspaces.firstIndex { $0.id == closed.workspaceID } ?? activeIndex
        activeWorkspaceID = workspaces[workspaceIndex].id
        workspaces[workspaceIndex].tabs.append(closed.app)

        if let groupID = closed.groupID,
           let groupIndex = workspaces[workspaceIndex].groups.firstIndex(where: { $0.id == groupID }) {
            let index = min(closed.childIndex ?? workspaces[workspaceIndex].groups[groupIndex].tabIDs.count,
                            workspaces[workspaceIndex].groups[groupIndex].tabIDs.count)
            workspaces[workspaceIndex].groups[groupIndex].tabIDs.insert(closed.app.id, at: index)
            workspaces[workspaceIndex].groups[groupIndex].isCollapsed = false
        } else {
            // A provisional two-tab group may have dissolved when this tab was
            // closed. Preserve its former child order when reopening the tab as
            // a loose sibling beside the one that remained.
            let childOffset = closed.groupID == nil ? 0 : min(closed.childIndex ?? 0, 1)
            let index = min(
                closed.topLevelIndex + childOffset,
                workspaces[workspaceIndex].sidebarItems.count
            )
            workspaces[workspaceIndex].sidebarItems.insert(.tab(closed.app.id), at: index)
        }

        selectedID = closed.app.id
        recordSelection(closed.app.id)
        persist()
        return closed.app
    }

    /// Compatibility entry point used by the existing Preferences list.
    func move(_ draggedID: WebApp.ID, before targetID: WebApp.ID) {
        moveTab(draggedID, before: targetID)
    }

    func moveTab(_ draggedID: WebApp.ID, before targetID: WebApp.ID) {
        guard draggedID != targetID,
              workspaces[activeIndex].tabs.contains(where: { $0.id == draggedID }),
              workspaces[activeIndex].tabs.contains(where: { $0.id == targetID }) else { return }

        if let targetGroup = group(containing: targetID) {
            moveTab(draggedID, toGroup: targetGroup.id, before: targetID)
        } else {
            moveTabToRoot(draggedID, beforeItem: targetID)
        }
    }

    func moveTab(_ tabID: WebApp.ID, toGroup groupID: TabGroup.ID, before targetID: WebApp.ID? = nil) {
        guard tabID != targetID else { return }
        guard workspaces[activeIndex].tabs.contains(where: { $0.id == tabID }),
              activeGroupIndex(groupID) != nil else { return }
        removeTabReference(tabID, from: activeIndex, pruneEmptyGroups: false)
        dissolveProvisionalSingletonGroups(in: activeIndex, excluding: groupID)
        pruneEmptyGroups(in: activeIndex, excluding: groupID)
        guard let groupIndex = activeGroupIndex(groupID) else { return }
        let insertIndex = targetID.flatMap {
            workspaces[activeIndex].groups[groupIndex].tabIDs.firstIndex(of: $0)
        } ?? workspaces[activeIndex].groups[groupIndex].tabIDs.count
        workspaces[activeIndex].groups[groupIndex].tabIDs.insert(tabID, at: insertIndex)
        workspaces[activeIndex].groups[groupIndex].isCollapsed = false
        if workspaces[activeIndex].groups[groupIndex].tabIDs.count >= 3 {
            confirmGroup(groupID)
        }
        persist()
    }

    func moveTabToRoot(_ tabID: WebApp.ID, beforeItem referenceID: UUID? = nil) {
        guard tabID != referenceID else { return }
        guard workspaces[activeIndex].tabs.contains(where: { $0.id == tabID }) else { return }
        removeTabReference(tabID, from: activeIndex, pruneEmptyGroups: true)
        let index = referenceID.flatMap { id in
            workspaces[activeIndex].sidebarItems.firstIndex { $0.referenceID == id }
        } ?? workspaces[activeIndex].sidebarItems.count
        workspaces[activeIndex].sidebarItems.insert(.tab(tabID), at: index)
        persist()
    }

    /// Dropping a tab on an ungrouped tab creates a group; dropping on a grouped
    /// tab joins that existing group. The dragged tab keeps its original ID.
    @discardableResult
    func combine(
        _ draggedID: WebApp.ID,
        with targetID: WebApp.ID,
        name: String = "Tab Group"
    ) -> TabGroup? {
        guard draggedID != targetID else { return group(containing: targetID) }
        if let targetGroup = group(containing: targetID) {
            moveTab(draggedID, toGroup: targetGroup.id, before: targetID)
            return group(targetGroup.id)
        }
        let group = addGroup(
            name: name,
            color: nextGroupColor(),
            containing: [targetID, draggedID]
        )
        provisionalGroups[group.id] = ProvisionalGroup(createdAt: provisionalNow())
        return group
    }

    /// Reorder from the flat Preferences list. Moving a child out of a group is
    /// explicit here, matching the result of dropping it at top level in the rail.
    func moveApps(fromOffsets source: IndexSet, toOffset destination: Int) {
        let ids = apps.map(\.id)
        let moving = source.sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }
        guard !moving.isEmpty else { return }
        let remaining = ids.filter { !moving.contains($0) }
        let adjusted = destination - source.filter { $0 < destination }.count
        let target = remaining.indices.contains(adjusted) ? remaining[adjusted] : nil
        for id in moving { moveTabToRoot(id, beforeItem: target) }
    }

    /// Add a tab record into a SPECIFIC workspace without changing that
    /// workspace's selection — used by the agent target sync, which mirrors
    /// agent-created Chromium pages into the rail while the user keeps their
    /// own place. Returns nil when the workspace does not exist.
    @discardableResult
    func addApp(title: String, urlString: String, toWorkspace workspaceID: UUID) -> WebApp? {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return nil
        }
        let app = WebApp(title: title, urlString: urlString)
        workspaces[workspaceIndex].tabs.append(app)
        workspaces[workspaceIndex].sidebarItems.append(.tab(app.id))
        workspaces[workspaceIndex].normalizeSidebar()
        persist()
        return app
    }

    /// Imports a Chrome session into one Space in Chrome's window/tab order.
    /// Peekr Spaces do not have a second window hierarchy, so multiple Chrome
    /// windows are flattened while their tab order, groups, pinning and active
    /// tab are retained.
    @discardableResult
    func importChromeSession(
        _ session: ChromeSessionSnapshot,
        intoWorkspace workspaceID: Workspace.ID? = nil
    ) -> ChromeSessionImportResult {
        let targetID = workspaceID ?? activeWorkspaceID
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == targetID }) else {
            return ChromeSessionImportResult(
                importedTabIDs: [],
                importedWindowCount: 0,
                importedGroupCount: 0,
                selectedTabID: nil
            )
        }

        var groupIndexes: [ChromeSessionGroupID: Int] = [:]
        var importedTabIDs: [WebApp.ID] = []
        var selectedTabID: WebApp.ID?

        for window in session.windows {
            for (tabIndex, importedTab) in window.tabs.enumerated() {
                let title = importedTab.title.isEmpty
                    ? (URL(string: importedTab.urlString)?.displayHost ?? importedTab.urlString)
                    : importedTab.title
                let app = WebApp(
                    title: title,
                    urlString: importedTab.urlString,
                    isPinned: importedTab.isPinned
                )
                workspaces[workspaceIndex].tabs.append(app)
                importedTabIDs.append(app.id)

                if let chromeGroupID = importedTab.groupID {
                    let groupIndex: Int
                    if let existing = groupIndexes[chromeGroupID] {
                        groupIndex = existing
                    } else {
                        let group = TabGroup(
                            name: "Tab Group",
                            color: .blue,
                            isCollapsed: false,
                            tabIDs: []
                        )
                        workspaces[workspaceIndex].groups.append(group)
                        groupIndex = workspaces[workspaceIndex].groups.count - 1
                        groupIndexes[chromeGroupID] = groupIndex
                        workspaces[workspaceIndex].sidebarItems.append(.group(group.id))
                    }
                    workspaces[workspaceIndex].groups[groupIndex].tabIDs.append(app.id)
                } else {
                    workspaces[workspaceIndex].sidebarItems.append(.tab(app.id))
                }

                if window.isActive,
                   tabIndex == window.selectedTabIndex {
                    selectedTabID = app.id
                }
            }
        }

        // Replace the placeholder group visuals with the metadata from Chrome.
        // Metadata is associated with a group through the first tab carrying
        // that group's opaque session ID.
        for (chromeGroupID, groupIndex) in groupIndexes {
            if let group = session.groups.first(where: { $0.id == chromeGroupID }) {
                workspaces[workspaceIndex].groups[groupIndex].name = group.name.isEmpty ? "Tab Group" : group.name
                workspaces[workspaceIndex].groups[groupIndex].color = group.color
                workspaces[workspaceIndex].groups[groupIndex].isCollapsed = group.isCollapsed
            }
        }

        if let selectedTabID {
            workspaces[workspaceIndex].selectedTabID = selectedTabID
            if workspaceIndex == activeIndex { recordSelection(selectedTabID) }
        }
        workspaces[workspaceIndex].normalizeSidebar()
        persist()

        return ChromeSessionImportResult(
            importedTabIDs: importedTabIDs,
            importedWindowCount: session.windows.count,
            importedGroupCount: groupIndexes.count,
            selectedTabID: selectedTabID
        )
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(
        name: String,
        color: TabGroupColor = .blue,
        containing tabIDs: [WebApp.ID] = []
    ) -> TabGroup {
        let validIDs = tabIDs.filter { id in
            workspaces[activeIndex].tabs.contains { $0.id == id }
        }
        let anchorID = validIDs.compactMap { topLevelReference(for: $0) }.first
        let insertion = anchorID.flatMap { id in
            workspaces[activeIndex].sidebarItems.firstIndex { $0.referenceID == id }
        } ?? workspaces[activeIndex].sidebarItems.count

        for id in validIDs { removeTabReference(id, from: activeIndex, pruneEmptyGroups: true) }
        let group = TabGroup(name: name, color: color, tabIDs: validIDs)
        workspaces[activeIndex].groups.append(group)
        workspaces[activeIndex].sidebarItems.insert(
            .group(group.id),
            at: min(insertion, workspaces[activeIndex].sidebarItems.count)
        )
        persist()
        return group
    }

    func renameGroup(_ id: TabGroup.ID, to name: String) {
        guard let index = activeGroupIndex(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[activeIndex].groups[index].name = trimmed.isEmpty ? "Tab Group" : trimmed
        confirmGroup(id)
        persist()
    }

    func recolorGroup(_ id: TabGroup.ID, to color: TabGroupColor) {
        guard let index = activeGroupIndex(id) else { return }
        workspaces[activeIndex].groups[index].color = color
        workspaces[activeIndex].groups[index].customColor = nil
        confirmGroup(id)
        persist()
    }

    func setCustomColor(_ color: TabGroupCustomColor, forGroup id: TabGroup.ID) {
        guard let index = activeGroupIndex(id) else { return }
        workspaces[activeIndex].groups[index].customColor = color
        confirmGroup(id)
        persist()
    }

    func toggleGroup(_ id: TabGroup.ID) {
        guard let index = activeGroupIndex(id) else { return }
        workspaces[activeIndex].groups[index].isCollapsed.toggle()
        confirmGroup(id)
        persist()
    }

    func moveGroup(_ id: TabGroup.ID, before referenceID: UUID?) {
        guard id != referenceID else { return }
        guard let from = workspaces[activeIndex].sidebarItems.firstIndex(where: {
            $0.kind == .group && $0.referenceID == id
        }) else { return }
        let item = workspaces[activeIndex].sidebarItems.remove(at: from)
        let to = referenceID.flatMap { ref in
            workspaces[activeIndex].sidebarItems.firstIndex { $0.referenceID == ref }
        } ?? workspaces[activeIndex].sidebarItems.count
        workspaces[activeIndex].sidebarItems.insert(item, at: to)
        confirmGroup(id)
        persist()
    }

    func ungroup(_ id: TabGroup.ID) {
        guard let groupIndex = activeGroupIndex(id),
              let itemIndex = workspaces[activeIndex].sidebarItems.firstIndex(where: {
                  $0.kind == .group && $0.referenceID == id
              }) else { return }
        let tabIDs = workspaces[activeIndex].groups[groupIndex].tabIDs
        workspaces[activeIndex].groups.remove(at: groupIndex)
        workspaces[activeIndex].sidebarItems.remove(at: itemIndex)
        provisionalGroups.removeValue(forKey: id)
        workspaces[activeIndex].sidebarItems.insert(
            contentsOf: tabIDs.map(SidebarItem.tab), at: itemIndex
        )
        persist()
    }

    func closeGroup(_ id: TabGroup.ID) {
        guard let group = group(id) else { return }
        let closing = Set(group.tabIDs)
        let oldOrder = activeWorkspace.orderedTabIDs
        let selectionIndex = selectedID.flatMap { oldOrder.firstIndex(of: $0) } ?? 0
        let nextIDs = oldOrder.filter { !closing.contains($0) }
        if let selectedID, closing.contains(selectedID) {
            self.selectedID = nextIDs.isEmpty ? nil : nextIDs[min(selectionIndex, nextIDs.count - 1)]
        }
        for tabID in group.tabIDs { removeApp(tabID) }
        if let remainingGroup = activeGroupIndex(id) {
            workspaces[activeIndex].groups.remove(at: remainingGroup)
        }
        workspaces[activeIndex].sidebarItems.removeAll {
            $0.kind == .group && $0.referenceID == id
        }
        persist()
    }

    @discardableResult
    func duplicateGroup(_ id: TabGroup.ID) -> TabGroup? {
        guard let source = group(id) else { return nil }
        confirmGroup(id)
        let copies = source.tabIDs.compactMap { tab($0) }.map {
            WebApp(title: $0.title, urlString: $0.urlString, alias: $0.alias)
        }
        workspaces[activeIndex].tabs.append(contentsOf: copies)
        let duplicate = TabGroup(
            name: source.name,
            color: source.color,
            customColor: source.customColor,
            isCollapsed: source.isCollapsed,
            tabIDs: copies.map(\.id)
        )
        workspaces[activeIndex].groups.append(duplicate)
        let sourceIndex = workspaces[activeIndex].sidebarItems.firstIndex {
            $0.kind == .group && $0.referenceID == id
        } ?? (workspaces[activeIndex].sidebarItems.count - 1)
        workspaces[activeIndex].sidebarItems.insert(
            .group(duplicate.id),
            at: min(sourceIndex + 1, workspaces[activeIndex].sidebarItems.count)
        )
        persist()
        return duplicate
    }

    // MARK: - Spaces

    var defaultProfile: BrowserProfile {
        profiles.first(where: \.isDefault) ?? .defaultProfile
    }

    func profile(_ id: BrowserProfile.ID) -> BrowserProfile? {
        profiles.first { $0.id == id }
    }

    func profile(forTab tabID: WebApp.ID) -> BrowserProfile {
        guard let workspace = workspaces.first(where: { workspace in
            workspace.tabs.contains { $0.id == tabID }
        }) else {
            return defaultProfile
        }
        return profile(workspace.profileID) ?? defaultProfile
    }

    @discardableResult
    func createProfile(name: String) -> BrowserProfile? {
        guard let profile = profileStore.create(name: name) else { return nil }
        profiles = profileStore.load().profiles
        return profile
    }

    @discardableResult
    func renameProfile(_ id: BrowserProfile.ID, to name: String) -> BrowserProfile? {
        guard let renamed = profileStore.rename(id, to: name) else { return nil }
        profiles = profileStore.load().profiles
        return renamed
    }

    @discardableResult
    func archiveProfile(_ id: BrowserProfile.ID) -> Bool {
        guard profileStore.archive(id) else { return false }
        profiles = profileStore.load().profiles
        return true
    }

    @discardableResult
    func deleteProfile(_ id: BrowserProfile.ID) -> Bool {
        let boundWorkspaceIDs = Set(workspaces.filter { $0.profileID == id }.map(\.id))
        guard profileStore.delete(id, boundWorkspaceIDs: boundWorkspaceIDs) else { return false }
        profiles = profileStore.load().profiles
        return true
    }

    @discardableResult
    func rebindWorkspace(_ workspaceID: Workspace.ID, to profileID: BrowserProfile.ID) -> Bool {
        guard profiles.contains(where: { $0.id == profileID && !$0.isArchived }),
              let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return false
        }
        let previousProfileID = workspaces[index].profileID
        guard previousProfileID != profileID else { return true }
        onWorkspaceProfileChange?(workspaceID, previousProfileID, profileID)
        workspaces[index].profileID = profileID
        persist()
        return true
    }

    func selectWorkspace(_ id: UUID) {
        guard id != activeWorkspaceID, workspaces.contains(where: { $0.id == id }) else { return }
        let previousID = activeWorkspaceID
        onWorkspaceSwitch?(previousID, id)
        activeWorkspaceID = id
        if selectedID == nil { selectedID = activeWorkspace.orderedTabIDs.first }
        if let selectedID { recordSelection(selectedID) }
        persist()
    }

    @discardableResult
    func addWorkspace(profileID: BrowserProfile.ID? = nil) -> Workspace {
        let provider = searchEngine()
        let tab = WebApp(
            title: provider.displayName,
            urlString: provider.homepageURL.absoluteString
        )
        let workspace = Workspace(
            profileID: resolvedProfileID(profileID),
            tabs: [tab]
        )
        onWorkspaceSwitch?(activeWorkspaceID, workspace.id)
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id
        recordSelection(tab.id)
        persist()
        return workspace
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = name
        persist()
    }

    func toggleWorkspacePin(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].isPinned.toggle()
        persist()
    }

    /// Moves a workspace before another workspace. Dropping across the pinned
    /// boundary places the item at that section's edge instead of allowing a
    /// temporary order that the next render would immediately undo.
    func moveWorkspace(_ id: UUID, before referenceID: UUID?) {
        var ordered = orderedWorkspaces
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == id }) else { return }
        let item = ordered.remove(at: sourceIndex)

        let insertionIndex: Int
        if let referenceID,
           let referenceIndex = ordered.firstIndex(where: { $0.id == referenceID }),
           ordered[referenceIndex].isPinned == item.isPinned {
            insertionIndex = referenceIndex
        } else if item.isPinned {
            insertionIndex = ordered.firstIndex(where: { !$0.isPinned }) ?? ordered.count
        } else if referenceID != nil {
            insertionIndex = ordered.firstIndex(where: { !$0.isPinned }) ?? ordered.count
        } else {
            insertionIndex = ordered.count
        }

        ordered.insert(item, at: insertionIndex)
        workspaces = ordered
        persist()
    }

    func removeWorkspace(_ id: UUID) {
        guard workspaces.count > 1,
              let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if activeWorkspaceID == id,
           let nextID = workspaces.first(where: { $0.id != id })?.id {
            onWorkspaceSwitch?(id, nextID)
        }
        let removedIDs = workspaces[index].tabs.map(\.id)
        let removedGroupIDs = workspaces[index].groups.map(\.id)
        workspaces.remove(at: index)
        for groupID in removedGroupIDs { provisionalGroups.removeValue(forKey: groupID) }
        if activeWorkspaceID == id { activeWorkspaceID = workspaces[0].id }
        selectionHistory.removeAll { removedIDs.contains($0) }
        persist()
        for tabID in removedIDs { onRemove?(tabID) }
    }

    // MARK: - Agent spaces

    /// Create a workspace for an AI agent to work in, seeded with one blank
    /// tab, and make it active. `agentOwner` labels the agent tool (e.g.
    /// "Claude Code"); empty means unidentified. The user can take the space
    /// over at any time — see `takeOverWorkspace(_:)`.
    @discardableResult
    func addAgentWorkspace(
        owner agentName: String = "",
        name: String = "",
        profileID: BrowserProfile.ID? = nil
    ) -> Workspace {
        let provider = searchEngine()
        let tab = WebApp(
            title: provider.displayName,
            urlString: provider.homepageURL.absoluteString
        )
        let workspace = Workspace(
            profileID: resolvedProfileID(profileID),
            name: name,
            tabs: [tab],
            ownership: .agent,
            agentOwner: agentName.trimmingCharacters(in: .whitespaces)
        )
        onWorkspaceSwitch?(activeWorkspaceID, workspace.id)
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id
        recordSelection(tab.id)
        persist()
        return workspace
    }

    /// The user takes an agent workspace over: it becomes a normal user space
    /// and keeps its tabs, groups and session. One-way on purpose — an agent
    /// that needs a fresh isolated area creates a new space instead of
    /// silently re-owning one the user is looking at.
    func takeOverWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].isAgentOwned else { return }
        workspaces[index].ownership = .user
        workspaces[index].agentOwner = ""
        persist()
    }

    /// The agent takes a user-owned (or handed-off) space over, e.g. after the
    /// user says "continue". Deliberate on both sides: the CLI helper maps its
    /// take-over flow here, and the rail badge flips with the ownership.
    @discardableResult
    func claimWorkspace(_ id: UUID, agentName: String = "") -> Workspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        workspaces[index].ownership = .agent
        let trimmed = agentName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { workspaces[index].agentOwner = trimmed }
        persist()
        return workspaces[index]
    }

    /// The agent hands control to the user (login, captcha, manual choice)
    /// while keeping the space agent-owned, matching ego-lite's
    /// `agentDelegatedToUser` state.
    @discardableResult
    func handOffWorkspace(_ id: UUID) -> Workspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].isAgentOwned else { return nil }
        workspaces[index].ownership = .agentDelegatedToUser
        persist()
        return workspaces[index]
    }

    // MARK: - Persistence and helpers

    private func resolvedProfileID(_ requested: BrowserProfile.ID?) -> BrowserProfile.ID {
        guard let requested,
              profiles.contains(where: { $0.id == requested && !$0.isArchived }) else {
            return BrowserProfile.defaultID
        }
        return requested
    }

    func persist() {
        pendingPersist?.cancel()
        normalizeWorkspaceOrder()
        for index in workspaces.indices { workspaces[index].normalizeSidebar() }
        store.save(WorkspacesData(workspaces: workspaces, activeWorkspaceID: activeWorkspaceID))
    }

    private func normalizeWorkspaceOrder() {
        workspaces = workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }

    private func schedulePersist() {
        pendingPersist?.cancel()
        pendingPersist = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func orderedApps(in workspace: Workspace) -> [WebApp] {
        let byID = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0) })
        return workspace.orderedTabIDs.compactMap { byID[$0] }
    }

    private func locate(_ id: WebApp.ID) -> (workspace: Int, tab: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let tabIndex = workspace.tabs.firstIndex(where: { $0.id == id }) {
                return (workspaceIndex, tabIndex)
            }
        }
        return nil
    }

    private func activeGroupIndex(_ id: TabGroup.ID) -> Int? {
        workspaces[activeIndex].groups.firstIndex { $0.id == id }
    }

    private func topLevelReference(for tabID: WebApp.ID) -> UUID? {
        group(containing: tabID)?.id ?? tabID
    }

    private func removeTabReference(
        _ tabID: WebApp.ID,
        from workspaceIndex: Int,
        pruneEmptyGroups: Bool
    ) {
        workspaces[workspaceIndex].sidebarItems.removeAll {
            $0.kind == .tab && $0.referenceID == tabID
        }
        for index in workspaces[workspaceIndex].groups.indices {
            workspaces[workspaceIndex].groups[index].tabIDs.removeAll { $0 == tabID }
        }
        guard pruneEmptyGroups else { return }
        dissolveProvisionalSingletonGroups(in: workspaceIndex)
        self.pruneEmptyGroups(in: workspaceIndex)
    }

    private func pruneEmptyGroups(in workspaceIndex: Int, excluding preservedID: TabGroup.ID? = nil) {
        let emptyIDs = Set(workspaces[workspaceIndex].groups.filter(\.tabIDs.isEmpty).map(\.id))
            .subtracting(preservedID.map { [$0] } ?? [])
        for id in emptyIDs { provisionalGroups.removeValue(forKey: id) }
        workspaces[workspaceIndex].groups.removeAll { emptyIDs.contains($0.id) }
        workspaces[workspaceIndex].sidebarItems.removeAll {
            $0.kind == .group && emptyIDs.contains($0.referenceID)
        }
    }

    /// Replace a still-temporary one-tab group with its remaining tab at the
    /// exact same top-level position. The destination group is excluded while a
    /// child is merely being reordered inside it.
    private func dissolveProvisionalSingletonGroups(
        in workspaceIndex: Int,
        excluding preservedID: TabGroup.ID? = nil
    ) {
        let candidateIDs = workspaces[workspaceIndex].groups.compactMap { group in
            group.id != preservedID && group.tabIDs.count == 1 ? group.id : nil
        }
        for id in candidateIDs where isLiveProvisionalGroup(id) {
            guard let groupIndex = workspaces[workspaceIndex].groups.firstIndex(where: { $0.id == id }),
                  let remainingID = workspaces[workspaceIndex].groups[groupIndex].tabIDs.first,
                  let itemIndex = workspaces[workspaceIndex].sidebarItems.firstIndex(where: {
                      $0.kind == .group && $0.referenceID == id
                  }) else { continue }
            workspaces[workspaceIndex].groups.remove(at: groupIndex)
            workspaces[workspaceIndex].sidebarItems[itemIndex] = .tab(remainingID)
            provisionalGroups.removeValue(forKey: id)
        }
    }

    private func isLiveProvisionalGroup(_ id: TabGroup.ID) -> Bool {
        guard let provisional = provisionalGroups[id] else { return false }
        let age = provisionalNow() - provisional.createdAt
        guard age >= 0, age < Self.provisionalGroupLifetime else {
            provisionalGroups.removeValue(forKey: id)
            return false
        }
        return true
    }

    private func confirmGroup(_ id: TabGroup.ID) {
        provisionalGroups.removeValue(forKey: id)
    }

    private func nextGroupColor() -> TabGroupColor {
        let colors = TabGroupColor.allCases.filter { $0 != .gray }
        return colors[workspaces[activeIndex].groups.count % colors.count]
    }

    private func recordSelection(_ id: WebApp.ID) {
        selectionHistory.removeAll { $0 == id }
        selectionHistory.insert(id, at: 0)
        if selectionHistory.count > 50 { selectionHistory.removeLast(selectionHistory.count - 50) }
    }
}
