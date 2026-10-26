import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Inject

/// Browser-grade vertical tab sidebar: Arc-like Spaces at the top and Edge-like
/// coloured, collapsible tab groups in one ordered tree beneath them.
struct AppRail: View {
    let model: AppModel
    let settings: Settings
    let icons: IconStore
    let badges: BadgeStore
    let width: CGFloat
    var onSelect: (UUID) -> Void
    var onNewTab: (TabGroup.ID?) -> Void
    var onEdit: (WebApp) -> Void
    var onWorkspaceSwitched: () -> Void
    var onOpenSpaces: () -> Void
    var onReopenClosedTab: () -> Void
    var onToggleMute: (UUID) -> Void
    var onToggleSleep: (UUID) -> Void
    var isAsleep: (UUID) -> Bool
    var onTabFocusChange: (Bool) -> Void
    var onCollapse: () -> Void

    @State private var dropTarget: String?
    @State private var dragged: RailDrag?
    @State private var dragCleanup: Task<Void, Never>?
    @State private var hoveringGroup: UUID?
    @State private var renamingTab: UUID?
    @State private var renamingGroup: UUID?
    @State private var renamingWorkspace: UUID?
    @State private var profileAction: ProfileAction?
    @State private var profileDraft = ""
    @State private var groupDraft = ""
    @State private var workspaceDraft = ""
    @ObserveInjection private var inject
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var groupFieldFocused: UUID?
    @FocusState private var workspaceFieldFocused: Bool
    @Namespace private var sidebarMotionNamespace

    private enum ProfileAction {
        case create
        case rename
    }

    private var loc: Localized { settings.strings }
    /// Keep the compact presentation stable while the divider is dragged. The
    /// stage still follows the pointer continuously; only the content layout
    /// changes once the rail is close enough to the icon-only anchor.
    private var showsIconOnlyLayout: Bool {
        width < (SidebarStage.iconOnly.width + SidebarStage.normal.width) / 2
    }

    var body: some View {
        Group {
            if showsIconOnlyLayout {
                compactRail
            } else {
                expandedRail
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Preserve AppKit's adaptive appearance. Liquid Glass can switch from
        // light to dark based on the content underneath it, so forcing a dark
        // scheme or painting a uniform tint here breaks both contrast and depth.
        .foregroundStyle(.primary)
        .enableInjection()
        .alert(profileAlertTitle, isPresented: Binding(
            get: { profileAction != nil },
            set: { if !$0 { profileAction = nil } }
        )) {
            TextField(loc.profileName, text: $profileDraft)
            Button(loc.cancel, role: .cancel) { profileAction = nil }
            Button(loc.save) { commitProfileAction() }
        }
    }

    private var expandedRail: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider().overlay(.primary.opacity(0.14)).padding(.horizontal, 12)
            tabTree
        }
    }

    /// A narrow vertical-tab rail modelled after Chrome's icon-only state. It
    /// keeps the workspace, group and tab actions available while dropping all
    /// labels so 64 px remains useful rather than becoming a dead collapse
    /// target.
    private var compactRail: some View {
        VStack(spacing: 0) {
            compactHeader
            Divider().overlay(.primary.opacity(0.14)).padding(.horizontal, 12)
            compactTabTree
        }
        .transition(.opacity)
    }

    private var compactHeader: some View {
        VStack(spacing: 6) {
            Button(action: onCollapse) {
                Image(systemName: settings.anchor.railOnLeft ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .help(loc.collapseSidebar)
            .accessibilityLabel(loc.collapseSidebar)

            if model.activeWorkspace.isPrivate {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 20)
                    .help(loc.privateSpaceName)
                    .accessibilityLabel(loc.privateSpace)
            }

            if !model.activeWorkspace.isPrivate {
                profileMenu
            }

            Button(action: onOpenSpaces) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .help(loc.openSpaces)
            .accessibilityLabel(loc.openSpaces)

            Menu { compactHeaderActions } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(loc.spaces)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var compactHeaderActions: some View {
        if model.activeWorkspace.isPrivate {
            Button(action: {}) {
                Label(loc.privateSpace, systemImage: "eye.slash")
            }
            .disabled(true)
        } else {
            profileMenu
        }
        Divider()
        Button { model.addGroup(name: loc.tabGroup, color: .blue) } label: {
            Label(loc.newTabGroup, systemImage: "rectangle.3.group")
        }
        Button {
            model.addWorkspace()
            onWorkspaceSwitched()
        } label: {
            Label(loc.newWorkspace, systemImage: "square.stack.3d.up.badge.a")
        }
        Button {
            model.addPrivateWorkspace()
            onWorkspaceSwitched()
        } label: {
            Label(loc.newPrivateSpace, systemImage: "eye.slash")
        }
        Button {
            model.addAgentWorkspace()
            onWorkspaceSwitched()
        } label: {
            Label(loc.newAgentWorkspace, systemImage: "sparkles")
        }
        Divider()
        Button { beginRenameWorkspace(model.activeWorkspace) } label: {
            Label(loc.rename, systemImage: "pencil")
        }
        if canRemoveActiveWorkspace {
            Button(role: .destructive) {
                model.removeWorkspace(model.activeWorkspaceID)
                onWorkspaceSwitched()
            } label: {
                Label(loc.delete, systemImage: "trash")
            }
        }
    }

    private var compactTabTree: some View {
        let snapshot = RailSnapshot(workspace: model.activeWorkspace)

        return ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(snapshot.workspace.sidebarItems) { item in
                    compactSidebarItem(item, snapshot: snapshot)
                }
                compactAddTabButton
                    .padding(.top, 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func compactSidebarItem(_ item: SidebarItem, snapshot: RailSnapshot) -> some View {
        switch item.kind {
        case .tab:
            if let app = snapshot.tabsByID[item.referenceID] {
                compactTabRow(app)
            }
        case .group:
            if let group = snapshot.groupsByID[item.referenceID] {
                compactGroupSection(group, tabsByID: snapshot.tabsByID)
            }
        }
    }

    private func compactGroupSection(_ group: TabGroup, tabsByID: [WebApp.ID: WebApp]) -> some View {
        VStack(spacing: 4) {
            Button { toggleGroup(group.id) } label: {
                Image(systemName: group.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.68))
                    .frame(width: 40, height: 28)
                    .background(group.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(group.name)
            .accessibilityLabel(group.name)
            .accessibilityValue(group.isCollapsed ? loc.expandGroup : loc.collapseGroup)
            .contextMenu { groupActions(group) }

            if !group.isCollapsed {
                VStack(spacing: 4) {
                    ForEach(group.tabIDs, id: \.self) { id in
                        if let app = tabsByID[id] { compactTabRow(app) }
                    }
                }
                .padding(.leading, 1)
                .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.sidebarCollapse, value: group.isCollapsed)
    }

    private func compactTabRow(_ app: WebApp) -> some View {
        let selected = app.id == model.selectedID
        let icon = icons.image(for: app)

        return Button {
            onTabFocusChange(true)
            onSelect(app.id)
        } label: {
            FaviconView(app: app, icon: icon, size: 27)
                .overlay(alignment: .topTrailing) {
                    if let unread = badges.count(for: app.id) {
                        UnreadBadge(count: unread)
                            .scaleEffect(0.78)
                            .offset(x: 5, y: -5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if model.audibleTabIDs.contains(app.id), !app.isMuted {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.9))
                            .padding(2.5)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
                            .offset(x: -3, y: 3)
                            .help(loc.playingAudio)
                            .accessibilityLabel(loc.playingAudio)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if app.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .offset(x: 3, y: 3)
                    }
                }
                .frame(width: 40, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.primary.opacity(selected ? 0.16 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(app.displayName)
        .accessibilityLabel(app.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button { onEdit(app) } label: { Label(loc.edit, systemImage: "pencil") }
            Button { renamingTab = app.id } label: { Label(loc.rename, systemImage: "character.cursor.ibeam") }
            Button { model.togglePin(app.id) } label: {
                Label(app.isPinned ? loc.unpinTab : loc.pinTab,
                      systemImage: app.isPinned ? "pin.slash" : "pin")
            }
            Button { onToggleMute(app.id) } label: {
                Label(app.isMuted ? loc.unmuteTab : loc.muteTab,
                      systemImage: app.isMuted ? "speaker.wave.2" : "speaker.slash")
            }
            Button { model.toggleKeepAwake(app.id) } label: {
                Label(app.keepAwake ? loc.allowSleep : loc.keepAwake,
                      systemImage: app.keepAwake ? "moon.zzz" : "moon.fill")
            }
            Button { onToggleSleep(app.id) } label: {
                Label(isAsleep(app.id) ? loc.wakePage : loc.sleepPage,
                      systemImage: isAsleep(app.id) ? "sun.max" : "moon.zzz")
            }
            Button {
                if let copy = model.duplicateTab(app.id) { onSelect(copy.id) }
            } label: { Label(loc.duplicateTab, systemImage: "plus.square.on.square") }
            if model.apps.count > 1 {
                Divider()
                Button { model.closeOtherTabs(keeping: app.id); onSelect(app.id) } label: {
                    Label(loc.closeOtherTabs, systemImage: "rectangle.on.rectangle.slash")
                }
                if let index = model.apps.firstIndex(where: { $0.id == app.id }),
                   index < model.apps.count - 1 {
                    Button { model.closeTabsToRight(of: app.id); onSelect(app.id) } label: {
                        Label(loc.closeTabsToRight, systemImage: "rectangle.rightthird.inset.filled")
                    }
                }
            }
            Divider()
            Button(role: .destructive) { close(app) } label: {
                Label(loc.closeTab, systemImage: "xmark")
            }
        }
    }

    private var compactAddTabButton: some View {
        Button { onNewTab(nil) } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .frame(width: 40, height: 32)
                .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(loc.newTab)
        .contextMenu {
            Button { onNewTab(nil) } label: { Label(loc.newTab, systemImage: "plus") }
            if model.hasRecentlyClosedTabs {
                Button(action: onReopenClosedTab) {
                    Label(loc.reopenClosedTab, systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    // MARK: - Spaces

    private var workspaceHeader: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Button(action: onCollapse) {
                    Image(systemName: settings.anchor.railOnLeft ? "sidebar.left" : "sidebar.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(.secondary)
                .help(loc.collapseSidebar)
                .accessibilityLabel(loc.collapseSidebar)
                .animation(reduceMotion ? nil : Motion.sidebarStyle, value: settings.anchor.railOnLeft)

                if renamingWorkspace == model.activeWorkspaceID {
                    TextField(workspaceTitle, text: $workspaceDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold))
                        .focused($workspaceFieldFocused)
                        .shadcnFocusRing(workspaceFieldFocused, cornerRadius: 6)
                        .onSubmit(commitRenameWorkspace)
                        .onExitCommand { renamingWorkspace = nil }
                } else if model.activeWorkspace.isPrivate {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(loc.privateSpace)
                }
                Spacer(minLength: 4)
                if !model.activeWorkspace.isPrivate {
                    profileMenu
                }
                Button(action: onOpenSpaces) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(.secondary)
                .help(loc.openSpaces)
                .accessibilityLabel(loc.openSpaces)
                Menu {
                    Button {
                        model.addGroup(name: loc.tabGroup, color: .blue)
                    } label: {
                        Label(loc.newTabGroup, systemImage: "rectangle.3.group")
                    }
                    Button {
                        model.addWorkspace()
                        onWorkspaceSwitched()
                    } label: {
                        Label(loc.newWorkspace, systemImage: "square.stack.3d.up.badge.a")
                    }
                    Button {
                        model.addPrivateWorkspace()
                        onWorkspaceSwitched()
                    } label: {
                        Label(loc.newPrivateSpace, systemImage: "eye.slash")
                    }
                    Button {
                        model.addAgentWorkspace()
                        onWorkspaceSwitched()
                    } label: {
                        Label(loc.newAgentWorkspace, systemImage: "sparkles")
                    }
                    Divider()
                    Button { beginRenameWorkspace(model.activeWorkspace) } label: {
                        Label(loc.rename, systemImage: "pencil")
                    }
                    if model.activeWorkspace.isAgentOwned {
                        Button {
                            model.takeOverWorkspace(model.activeWorkspaceID)
                        } label: {
                            Label(loc.takeOverWorkspace, systemImage: "hand.tap")
                        }
                    }
                    if canRemoveActiveWorkspace {
                        Button(role: .destructive) {
                            model.removeWorkspace(model.activeWorkspaceID)
                            onWorkspaceSwitched()
                        } label: {
                            Label(loc.delete, systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(loc.newWorkspace)
            }

        }
        .padding(.horizontal, 13)
        .padding(.bottom, 14)
    }

    private var activeProfile: BrowserProfile {
        model.profile(model.activeWorkspace.profileID) ?? model.defaultProfile
    }

    private var workspaceTitle: String {
        let workspace = model.activeWorkspace
        if workspace.isPrivate { return loc.privateSpaceName }
        return workspace.name.isEmpty ? loc.defaultWorkspace : workspace.name
    }

    private var canRemoveActiveWorkspace: Bool {
        let workspace = model.activeWorkspace
        guard model.workspaces.count > 1 else { return false }
        if workspace.isPrivate { return true }
        return model.workspaces.contains { !$0.isPrivate && $0.id != workspace.id }
    }

    private var profileAlertTitle: String {
        profileAction == .create ? loc.newProfile : loc.renameProfile
    }

    private var profileMenu: some View {
        Menu {
            Section(loc.chooseProfile) {
                ForEach(model.profiles.filter { !$0.isArchived }) { profile in
                    Button {
                        if model.rebindWorkspace(model.activeWorkspaceID, to: profile.id) {
                            onWorkspaceSwitched()
                        }
                    } label: {
                        Label {
                            Text(profile.name)
                        } icon: {
                            Image(systemName: profile.id == activeProfile.id
                                  ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            Divider()
            Button {
                profileDraft = ""
                profileAction = .create
            } label: {
                Label(loc.newProfile, systemImage: "plus")
            }
            if !activeProfile.isDefault {
                Button {
                    profileDraft = activeProfile.name
                    profileAction = .rename
                } label: {
                    Label(loc.renameProfile, systemImage: "pencil")
                }
                Button(role: .destructive) {
                    _ = model.archiveProfile(activeProfile.id)
                } label: {
                    Label(loc.archiveProfile, systemImage: "archivebox")
                }
            }
        } label: {
            ProfileAvatarView(profile: activeProfile, size: 23)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .fixedSize()
        .help(activeProfile.name)
        .accessibilityLabel(loc.profile)
    }

    private func commitProfileAction() {
        let name = profileDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let action = profileAction else {
            profileAction = nil
            return
        }
        switch action {
        case .create:
            _ = model.createProfile(name: name)
        case .rename:
            _ = model.renameProfile(activeProfile.id, to: name)
        }
        profileAction = nil
    }

    private func beginRenameWorkspace(_ workspace: Workspace) {
        if workspace.id != model.activeWorkspaceID {
            model.selectWorkspace(workspace.id)
            onWorkspaceSwitched()
        }
        workspaceDraft = workspace.name
        renamingWorkspace = workspace.id
        workspaceFieldFocused = true
    }

    private func commitRenameWorkspace() {
        if let id = renamingWorkspace {
            model.renameWorkspace(id, to: workspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        renamingWorkspace = nil
    }

    // MARK: - Hierarchical tab tree

    private var tabTree: some View {
        let snapshot = RailSnapshot(workspace: model.activeWorkspace)

        return ScrollView {
            if #available(macOS 27.0, *) {
                nativeReorderList(snapshot: snapshot)
            } else {
                manualReorderList(snapshot: snapshot)
            }
        }
        .modifier(RailRootDropFallback(
            isActive: { dragged != nil },
            onMove: { cancelDragCleanup() },
            onExit: { scheduleDragCleanup() },
            onPerform: {
                moveDragToEnd()
                endDrag()
            }
        ))
    }

    /// macOS 27 native reordering: the system draws the insertion placeholder
    /// and the push-aside animation, and reports one difference when the drag
    /// ends — no per-row drop delegates or hand-rolled placeholder.
    @available(macOS 27.0, *)
    private func nativeReorderList(snapshot: RailSnapshot) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(snapshot.workspace.sidebarItems) { item in
                sidebarItem(item, snapshot: snapshot)
            }
            .reorderable(collectionID: RailCollectionID.root)
            addTabButton
                .padding(.top, 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(
            reduceMotion ? nil : Motion.sidebarReorder,
            value: snapshot.workspace.sidebarItems
        )
        .reorderContainer(
            for: SidebarItem.self,
            itemID: \.referenceID,
            in: RailCollectionID.self
        ) { difference in
            applyReorder(difference)
        }
    }

    private func manualReorderList(snapshot: RailSnapshot) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(snapshot.workspace.sidebarItems) { item in
                sidebarItem(item, snapshot: snapshot)
            }
            addTabButton
                .padding(.top, 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(
            reduceMotion ? nil : Motion.sidebarReorder,
            value: snapshot.workspace.sidebarItems
        )
    }

    @available(macOS 27.0, *)
    private func applyReorder(_ difference: ReorderDifference<UUID, RailCollectionID>) {
        guard !difference.sources.isEmpty else { return }
        var groupID: TabGroup.ID?
        switch difference.destination.collectionID {
        case .root: groupID = nil
        case .group(let id): groupID = id
        }
        var before: UUID?
        switch difference.destination.position {
        case .before(let id): before = id
        case .end: before = nil
        }
        withSidebarReorder {
            model.applySidebarReorder(
                sources: difference.sources,
                toGroup: groupID,
                before: before
            )
        }
    }

    /// Dropping anywhere outside a row (below the list, above it, side padding)
    /// sends the item to the end.
    private func moveDragToEnd() {
        guard let drag = dragged else { return }
        cancelDragCleanup()
        let items = model.activeWorkspace.sidebarItems
        switch drag {
        case .tab(let id):
            let reference = model.activeWorkspace.group(containing: id)?.id ?? id
            guard items.last?.referenceID != reference else { return }
            withSidebarReorder { model.moveTabToRoot(id) }
        case .group(let id):
            guard !(items.last?.kind == .group && items.last?.referenceID == id) else { return }
            withSidebarReorder { model.moveGroup(id, before: nil) }
        }
    }

    @ViewBuilder
    private func sidebarItem(_ item: SidebarItem, snapshot: RailSnapshot) -> some View {
        switch item.kind {
        case .tab:
            if let app = snapshot.tabsByID[item.referenceID] {
                tabRow(app, group: nil)
            }
        case .group:
            if let group = snapshot.groupsByID[item.referenceID] {
                groupSection(group, tabsByID: snapshot.tabsByID)
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: TabGroup, tabsByID: [WebApp.ID: WebApp]) -> some View {
        if #available(macOS 27.0, *) {
            groupSectionBody(group) { items in
                ForEach(items, id: \.referenceID) { item in
                    if let app = tabsByID[item.referenceID] { tabRow(app, group: group) }
                }
                .reorderable(collectionID: RailCollectionID.group(group.id))
            }
            .padding(.vertical, 2.5)
        } else {
            groupSectionBody(group) { items in
                ForEach(items, id: \.referenceID) { item in
                    if let app = tabsByID[item.referenceID] { tabRow(app, group: group) }
                }
            }
            .matchedGeometryEffect(
                id: RailDrag.group(group.id).encoded,
                in: sidebarMotionNamespace,
                properties: .frame
            )
            .padding(.vertical, 2.5)
            .opacity(dragged == .group(group.id) ? 0.4 : 1)
            .onDrop(of: [UTType.text], delegate: RailDropDelegate(
                isActive: { dragged != .group(group.id) },
                onMove: { y in
                    liveDrop(onto: .group(group.id), y: y, half: 20)
                },
                onExit: { scheduleDragCleanup() },
                onPerform: { endDrag() }
            ))
        }
    }

    private func groupSectionBody<Rows: View>(
        _ group: TabGroup,
        @ViewBuilder rows: ([SidebarItem]) -> Rows
    ) -> some View {
        VStack(spacing: 0) {
            groupHeader(group)
            // Keep disappearing rows inside their own clipping region. SwiftUI
            // keeps a removed transition alive while the parent height shrinks;
            // without this boundary those rows paint over the header above.
            VStack(spacing: 0) {
                if !group.isCollapsed {
                    HStack(alignment: .top, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(group.tint)
                            .frame(width: 2)
                            .padding(.vertical, 2)

                        LazyVStack(spacing: 0) {
                            rows(group.tabIDs.map(SidebarItem.tab))
                            if group.tabIDs.isEmpty {
                                Button { onNewTab(group.id) } label: {
                                    Label(loc.newTabInGroup, systemImage: "plus")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .animation(
                            reduceMotion ? nil : Motion.sidebarReorder,
                            value: group.tabIDs
                        )
                    }
                    .padding(4)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                }
            }
            .clipped()
        }
    }

    private func groupHeaderBase(_ group: TabGroup) -> some View {
        let showsMenu = hoveringGroup == group.id || renamingGroup == group.id

        return HStack(spacing: 8) {
            if renamingGroup == group.id {
                TextField(loc.tabGroup, text: $groupDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.84))
                    .focused($groupFieldFocused, equals: group.id)
                    .noFocusRing()
                    .onSubmit { commitRenameGroup(group.id) }
                    .onExitCommand { renamingGroup = nil }
            } else {
                Text(group.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.84))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginRenameGroup(group) }
            }
            Spacer(minLength: 0)
            groupMenu(group)
                .opacity(showsMenu ? 1 : 0)
                .allowsHitTesting(showsMenu)
                .accessibilityHidden(!showsMenu)
                .animation(
                    reduceMotion ? nil : Motion.controlFeedback,
                    value: showsMenu
                )
            Button { toggleGroup(group.id) } label: {
                Image(systemName: group.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.62))
                    .frame(width: 18, height: 24)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(
                        reduceMotion ? nil : Motion.iconSwap,
                        value: group.isCollapsed
                    )
            }
            .buttonStyle(.plain)
            .help(group.isCollapsed ? loc.expandGroup : loc.collapseGroup)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            group.tint,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            if dropTarget == RailDrag.group(group.id).encoded {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.primary.opacity(0.72), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .animation(
            reduceMotion ? nil : Motion.sidebarStyle,
            value: group.color
        )
        .animation(
            reduceMotion ? nil : Motion.sidebarStyle,
            value: group.customColor
        )
        .onHover { hoveringGroup = $0 ? group.id : nil }
        .onTapGesture { if renamingGroup == nil { toggleGroup(group.id) } }
        .overlay {
            TabGroupContextMenuOverlay(
                group: group,
                strings: loc,
                onRename: { model.renameGroup(group.id, to: $0) },
                onRecolor: { model.recolorGroup(group.id, to: $0) },
                onCustomColor: { model.setCustomColor($0, forGroup: group.id) },
                onNewTab: { onNewTab(group.id) },
                onDuplicate: { model.duplicateGroup(group.id) },
                onClose: { close(group) },
                onUngroup: { model.ungroup(group.id) }
            )
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: TabGroup) -> some View {
        if #available(macOS 27.0, *) {
            groupHeaderBase(group)
        } else {
            groupHeaderBase(group)
                .onDrag {
                    beginDrag(.group(group.id))
                    return NSItemProvider(object: RailDrag.group(group.id).encoded as NSString)
                } preview: {
                    groupDragPreview(group)
                }
                .pointerCursor(.openHand)
                .onDrop(of: [UTType.text], delegate: RailDropDelegate(
                    isActive: { dragged != .group(group.id) },
                    onMove: { y in
                        liveDrop(onto: .group(group.id), y: y, half: Self.groupHeaderDropHalf)
                    },
                    onExit: { scheduleDragCleanup() },
                    onPerform: { endDrag() }
                ))
        }
    }

    private func groupDragPreview(_ group: TabGroup) -> some View {
        Text(group.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.84))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                group.tint,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }

    private func groupMenu(_ group: TabGroup) -> some View {
        Menu {
            groupActions(group)
        } label: {
            Image(systemName: "ellipsis.vertical")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func groupActions(_ group: TabGroup) -> some View {
        Button { onNewTab(group.id) } label: {
            Label(loc.newTabInGroup, systemImage: "plus")
        }
        Button { beginRenameGroup(group) } label: {
            Label(loc.rename, systemImage: "pencil")
        }
        Picker(
            loc.groupColor,
            selection: Binding(
                get: { group.color },
                set: { model.recolorGroup(group.id, to: $0) }
            )
        ) {
            ForEach(TabGroupColor.allCases, id: \.self) { color in
                Label(color.displayName(chinese: loc.isChinese), systemImage: "circle.fill")
                    .tag(color)
            }
        }
        .pickerStyle(.menu)
        ColorPicker(
            loc.customColor,
            selection: Binding(
                get: { group.tint },
                set: { color in
                    guard let customColor = TabGroupCustomColor(color: color) else { return }
                    model.setCustomColor(customColor, forGroup: group.id)
                }
            ),
            supportsOpacity: false
        )
        Divider()
        Button { model.duplicateGroup(group.id) } label: {
            Label(loc.duplicateGroup, systemImage: "plus.square.on.square")
        }
        Button { model.ungroup(group.id) } label: {
            Label(loc.ungroup, systemImage: "rectangle.3.group.bubble.left")
        }
        Divider()
        Button(role: .destructive) { close(group) } label: {
            Label(loc.closeGroup, systemImage: "xmark")
        }
    }

    @ViewBuilder
    private func tabRow(_ app: WebApp, group: TabGroup?) -> some View {
        if #available(macOS 27.0, *) {
            tabRowBase(app, group: group)
        } else {
            tabRowBase(app, group: group)
                .matchedGeometryEffect(
                    id: RailDrag.tab(app.id).encoded,
                    in: sidebarMotionNamespace,
                    properties: .frame
                )
                .opacity(dragged == .tab(app.id) ? 0 : 1)
                .overlay {
                    if dragged == .tab(app.id) {
                        railPlaceholder(tint: group?.tint)
                    }
                }
                .onDrag {
                    beginDrag(.tab(app.id))
                    return NSItemProvider(object: RailDrag.tab(app.id).encoded as NSString)
                } preview: {
                    railDragPreview(app: app, shadowTint: group?.shadowTint)
                }
                .pointerCursor(.openHand)
                .onDrop(of: [UTType.text], delegate: RailDropDelegate(
                    isActive: { dragged != .tab(app.id) },
                    onMove: { y in
                        liveDrop(onto: .tab(app.id), y: y, half: Self.tabDropHalf)
                    },
                    onExit: { scheduleDragCleanup() },
                    onPerform: { endDrag() }
                ))
        }
    }

    private func tabRowBase(_ app: WebApp, group: TabGroup?) -> some View {
        let icon = icons.image(for: app)

        return BrowserTabRow(
            app: app,
            selected: app.id == model.selectedID,
            targeted: dropTarget == RailDrag.tab(app.id).encoded,
            groupTint: group?.tint,
            icon: icon,
            isRenaming: renamingTab == app.id,
            unread: badges.count(for: app.id),
            closeLabel: loc.closeTab,
            mutedLabel: loc.mutedTab,
            playingAudio: model.audibleTabIDs.contains(app.id),
            playingAudioLabel: loc.playingAudio,
            onSelect: { if renamingTab == nil { onSelect(app.id) } },
            onFocusChange: onTabFocusChange,
            onClose: { close(app) },
            onCommitRename: {
                model.setAlias(app.id, to: $0.trimmingCharacters(in: .whitespacesAndNewlines))
                renamingTab = nil
            },
            onCancelRename: { renamingTab = nil }
        )
        // Fold the inter-row gap into the row's own slot.
        .padding(.vertical, 2.5)
        .pointerCursor(.openHand)
        .contextMenu {
            Button { onEdit(app) } label: { Label(loc.edit, systemImage: "pencil") }
            Button { renamingTab = app.id } label: { Label(loc.rename, systemImage: "character.cursor.ibeam") }
            Button { model.togglePin(app.id) } label: {
                Label(app.isPinned ? loc.unpinTab : loc.pinTab,
                      systemImage: app.isPinned ? "pin.slash" : "pin")
            }
            Button { onToggleMute(app.id) } label: {
                Label(app.isMuted ? loc.unmuteTab : loc.muteTab,
                      systemImage: app.isMuted ? "speaker.wave.2" : "speaker.slash")
            }
            Button { model.toggleKeepAwake(app.id) } label: {
                Label(app.keepAwake ? loc.allowSleep : loc.keepAwake,
                      systemImage: app.keepAwake ? "moon.zzz" : "moon.fill")
            }
            Button { onToggleSleep(app.id) } label: {
                Label(isAsleep(app.id) ? loc.wakePage : loc.sleepPage,
                      systemImage: isAsleep(app.id) ? "sun.max" : "moon.zzz")
            }
            Button {
                if let copy = model.duplicateTab(app.id) { onSelect(copy.id) }
            } label: { Label(loc.duplicateTab, systemImage: "plus.square.on.square") }
            Button {
                icons.refresh(app) { model.rename(app.id, to: $0) }
            } label: { Label(loc.refreshIconAndTitle, systemImage: "arrow.clockwise") }
            Divider()
            if !model.activeWorkspace.groups.isEmpty {
                Menu(loc.moveToGroup) {
                    ForEach(model.activeWorkspace.groups) { destination in
                        Button(destination.name) {
                            model.moveTab(app.id, toGroup: destination.id)
                        }
                    }
                    Divider()
                    Button(loc.newTabGroup) {
                        model.addGroup(name: loc.tabGroup, color: .blue, containing: [app.id])
                    }
                }
            } else {
                Button {
                    model.addGroup(name: loc.tabGroup, color: .blue, containing: [app.id])
                } label: {
                    Label(loc.newTabGroup, systemImage: "rectangle.3.group")
                }
            }
            if group != nil {
                Button { model.moveTabToRoot(app.id) } label: {
                    Label(loc.removeFromGroup, systemImage: "arrowshape.turn.up.left")
                }
            }
            if model.apps.count > 1 {
                Divider()
                Button { model.closeOtherTabs(keeping: app.id); onSelect(app.id) } label: {
                    Label(loc.closeOtherTabs, systemImage: "rectangle.on.rectangle.slash")
                }
                if let index = model.apps.firstIndex(where: { $0.id == app.id }),
                   index < model.apps.count - 1 {
                    Button { model.closeTabsToRight(of: app.id); onSelect(app.id) } label: {
                        Label(loc.closeTabsToRight, systemImage: "rectangle.rightthird.inset.filled")
                    }
                }
            }
            Divider()
            Button(role: .destructive) { close(app) } label: {
                Label(loc.closeTab, systemImage: "xmark")
            }
        }
    }

    private var addTabButton: some View {
        Button { onNewTab(nil) } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(loc.newTab)
        .contextMenu {
            Button { onNewTab(nil) } label: { Label(loc.newTab, systemImage: "plus") }
            Button { model.addGroup(name: loc.tabGroup, color: .blue) } label: {
                Label(loc.newTabGroup, systemImage: "rectangle.3.group")
            }
            if model.hasRecentlyClosedTabs {
                Divider()
                Button(action: onReopenClosedTab) {
                    Label(loc.reopenClosedTab, systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private func beginRenameGroup(_ group: TabGroup) {
        groupDraft = group.name
        renamingGroup = group.id
        groupFieldFocused = group.id
    }

    private func commitRenameGroup(_ id: TabGroup.ID) {
        model.renameGroup(id, to: groupDraft)
        renamingGroup = nil
    }

    private func close(_ app: WebApp) {
        let wasSelected = model.selectedID == app.id
        model.removeApp(app.id)
        if wasSelected, let id = model.selectedID { onSelect(id) }
    }

    private func close(_ group: TabGroup) {
        let closedSelected = model.selectedID.map(group.tabIDs.contains) ?? false
        model.closeGroup(group.id)
        if closedSelected, let id = model.selectedID { onSelect(id) }
    }

    private func setDropTarget(_ target: String?) {
        withAnimation(reduceMotion ? nil : Motion.sidebarDropTarget) {
            dropTarget = target
        }
    }

    /// Slot shown in place of a tab while it is being dragged (manual path).
    private func railPlaceholder(tint: Color?) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill((tint ?? .primary).opacity(0.12))
            .frame(height: 32)
    }

    /// Snapshot shown under the pointer for a dragged tab.
    private func railDragPreview(app: WebApp, shadowTint: Color?) -> some View {
        HStack(spacing: 8) {
            FaviconView(app: app, icon: icons.image(for: app), size: 16)
            Text(app.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: shadowTint ?? .clear, radius: 6, y: 2)
    }

    private func withSidebarReorder(_ mutation: () -> Void) {
        withAnimation(reduceMotion ? nil : Motion.sidebarReorder, mutation)
    }

    private func toggleGroup(_ id: TabGroup.ID) {
        withAnimation(reduceMotion ? nil : Motion.sidebarCollapse) {
            model.toggleGroup(id)
        }
    }

    // MARK: - Live drag & drop

    private static let tabDropHalf: CGFloat = 18.5      // (32 + 2×2.5) / 2
    private static let groupHeaderDropHalf: CGFloat = 13 // header height 26 / 2

    /// Start a drag. The source row swaps to a placeholder while the drag is in
    /// flight, so the list shows a slot that follows the pointer and pushes its
    /// neighbours aside — the behaviour of a sortable list.
    private func beginDrag(_ drag: RailDrag) {
        cancelDragCleanup()
        if dragged != drag { dragged = drag }
        setDropTarget(nil)
    }

    private func endDrag() {
        cancelDragCleanup()
        dragged = nil
        setDropTarget(nil)
    }

    /// A cancelled drag fires `dropExited` but never `performDrop`; clear the
    /// placeholder shortly after leaving every target and cancel that cleanup as
    /// soon as the drag enters another target.
    private func cancelDragCleanup() {
        dragCleanup?.cancel()
        dragCleanup = nil
    }

    private func scheduleDragCleanup() {
        cancelDragCleanup()
        dragCleanup = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            dragged = nil
            setDropTarget(nil)
        }
    }

    /// Live reorder as the pointer moves over a target. `y` is the pointer's
    /// position in the target's own coordinate space; `half` its half-height.
    private func liveDrop(onto target: RailDrag, y: CGFloat, half: CGFloat) {
        guard let drag = dragged, drag != target else { return }
        cancelDragCleanup()
        setDropTarget(target.encoded)
        applyDrop(drag, onto: target, below: y > half)
    }

    /// Reorder the dragged item so it sits directly before/after the target.
    /// Adjacency is checked first so a stationary pointer does not re-insert the
    /// item on every `dropUpdated`, which would thrash the animation.
    private func applyDrop(_ drag: RailDrag, onto target: RailDrag, below: Bool) {
        let workspace = model.activeWorkspace
        switch (drag, target) {
        case let (.tab(draggedID), .tab(targetID)):
            if let group = workspace.group(containing: targetID) {
                guard let to = group.tabIDs.firstIndex(of: targetID) else { return }
                if let from = group.tabIDs.firstIndex(of: draggedID) {
                    if below, from == to + 1 { return }
                    if !below, from == to - 1 { return }
                }
                let reference = below
                    ? nextTabReference(after: targetID, in: group)
                    : targetID
                withSidebarReorder {
                    model.moveTab(draggedID, toGroup: group.id, before: reference)
                }
            } else {
                let draggedReference = workspace.group(containing: draggedID)?.id ?? draggedID
                let items = workspace.sidebarItems
                guard let from = items.firstIndex(where: { $0.referenceID == draggedReference }),
                      let to = items.firstIndex(where: { $0.referenceID == targetID }) else { return }
                // Only skip when the dragged item is itself a top-level sibling
                // of the target; a tab being pulled out of a group is not.
                if draggedReference == draggedID {
                    if below, from == to + 1 { return }
                    if !below, from == to - 1 { return }
                }
                let reference = below
                    ? nextTopLevelReference(after: targetID)
                    : targetID
                withSidebarReorder {
                    model.moveTabToRoot(draggedID, beforeItem: reference)
                }
            }

        case let (.tab(draggedID), .group(groupID)):
            guard let group = model.group(groupID), draggedID != group.tabIDs.last else { return }
            withSidebarReorder { model.moveTab(draggedID, toGroup: groupID) }

        case let (.group(draggedID), .tab(targetID)),
             let (.group(draggedID), .group(targetID)):
            let items = workspace.sidebarItems
            guard let from = items.firstIndex(where: {
                      $0.kind == .group && $0.referenceID == draggedID
                  }),
                  let to = items.firstIndex(where: { $0.referenceID == targetID }) else { return }
            if below, from == to + 1 { return }
            if !below, from == to - 1 { return }
            let reference = below ? nextTopLevelReference(after: targetID) : targetID
            withSidebarReorder { model.moveGroup(draggedID, before: reference) }

        default:
            break
        }
    }

    private func nextTabReference(after tabID: WebApp.ID, in group: TabGroup) -> WebApp.ID? {
        guard let index = group.tabIDs.firstIndex(of: tabID) else { return nil }
        return group.tabIDs.indices.contains(index + 1) ? group.tabIDs[index + 1] : nil
    }

    private func nextTopLevelReference(after referenceID: UUID) -> UUID? {
        let items = model.activeWorkspace.sidebarItems
        guard let index = items.firstIndex(where: { $0.referenceID == referenceID }) else { return nil }
        return items.indices.contains(index + 1) ? items[index + 1].referenceID : nil
    }
}

private enum RailDrag: Hashable {
    case tab(UUID)
    case group(UUID)

    init?(_ encoded: String) {
        let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "tab": self = .tab(id)
        case "group": self = .group(id)
        default: return nil
        }
    }

    var encoded: String {
        switch self {
        case .tab(let id): return "tab:\(id.uuidString)"
        case .group(let id): return "group:\(id.uuidString)"
        }
    }
}

/// Live-reorder drop delegate. Unlike `dropDestination`, a `DropDelegate`
/// receives a continuous pointer location, so the sidebar can be reordered
/// while the drag is still in flight and the placeholder animates into place.
private struct RailDropDelegate: DropDelegate {
    let isActive: () -> Bool
    let onMove: (CGFloat) -> Void
    let onExit: () -> Void
    let onPerform: () -> Void

    func validateDrop(info: DropInfo) -> Bool { isActive() }
    func dropEntered(info: DropInfo) { onMove(info.location.y) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        onMove(info.location.y)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { onExit() }
    func performDrop(info: DropInfo) -> Bool {
        onPerform()
        return true
    }
}

/// Identifies one native reorder collection: the top-level list or one group's
/// child list. macOS 27 uses it to route a drop to the right collection.
@available(macOS 27.0, *)
private enum RailCollectionID: Hashable, Sendable {
    case root
    case group(TabGroup.ID)
}

/// The manual path's root drop target. macOS 27 uses the native reorder
/// container instead, so this is a no-op there.
private struct RailRootDropFallback: ViewModifier {
    let isActive: () -> Bool
    let onMove: () -> Void
    let onExit: () -> Void
    let onPerform: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content
        } else {
            content.onDrop(of: [UTType.text], delegate: RailDropDelegate(
                isActive: isActive,
                onMove: { _ in onMove() },
                onExit: onExit,
                onPerform: onPerform
            ))
        }
    }
}

/// One render-pass lookup table for the active workspace. Without this snapshot,
/// every visible row calls back into `AppModel.locate`, turning a full sidebar
/// refresh into repeated scans across every workspace and tab.
private struct RailSnapshot {
    let workspace: Workspace
    let tabsByID: [WebApp.ID: WebApp]
    let groupsByID: [TabGroup.ID: TabGroup]

    init(workspace: Workspace) {
        self.workspace = workspace
        tabsByID = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0) })
        groupsByID = Dictionary(uniqueKeysWithValues: workspace.groups.map { ($0.id, $0) })
    }
}

extension TabGroupColor {
    static let palette: [TabGroupColor] = [
        .gray, .blue, .red, .yellow, .green, .pink, .purple, .cyan, .orange
    ]

    var tint: Color {
        switch self {
        case .blue: return Color(red: 0.43, green: 0.65, blue: 0.98)
        case .purple: return Color(red: 0.65, green: 0.49, blue: 0.93)
        case .pink: return Color(red: 0.97, green: 0.48, blue: 0.75)
        case .red: return Color(red: 0.96, green: 0.46, blue: 0.42)
        case .orange: return Color(red: 0.98, green: 0.63, blue: 0.32)
        case .green: return Color(red: 0.43, green: 0.78, blue: 0.55)
        case .gray: return Color(red: 0.62, green: 0.65, blue: 0.69)
        case .yellow: return Color(red: 0.98, green: 0.78, blue: 0.31)
        case .cyan: return Color(red: 0.37, green: 0.76, blue: 0.84)
        }
    }

    func displayName(chinese: Bool) -> String {
        switch self {
        case .blue: return chinese ? "蓝色" : "Blue"
        case .purple: return chinese ? "紫色" : "Purple"
        case .pink: return chinese ? "粉色" : "Pink"
        case .red: return chinese ? "红色" : "Red"
        case .orange: return chinese ? "橙色" : "Orange"
        case .green: return chinese ? "绿色" : "Green"
        case .gray: return chinese ? "灰色" : "Gray"
        case .yellow: return chinese ? "黄色" : "Yellow"
        case .cyan: return chinese ? "青色" : "Cyan"
        }
    }
}

extension TabGroupCustomColor {
    var tint: Color {
        Color(red: red, green: green, blue: blue)
    }

    init?(color: Color) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent)
        )
    }
}

extension TabGroup {
    var tint: Color { customColor?.tint ?? color.tint }

    /// Lightened HSL variant of the group tint: the elevation shadow cast by a
    /// dragging tab preview is conducted from the group color.
    var shadowTint: Color {
        guard let rgb = NSColor(tint).usingColorSpace(.sRGB) else { return tint.opacity(0.5) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let maxC = max(r, g, b), minC = min(r, g, b)
        let lightness = (maxC + minC) / 2
        let delta = maxC - minC
        var hue: CGFloat = 0, saturation: CGFloat = 0
        if delta > 0 {
            saturation = lightness > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
            switch maxC {
            case r: hue = (g - b) / delta + (g < b ? 6 : 0)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue /= 6
        }
        let lifted = lightness + (1 - lightness) * 0.45
        // SwiftUI's Color only takes HSB; convert the lifted HSL across.
        let value = lifted + saturation * min(lifted, 1 - lifted)
        let valueSaturation = value > 0 ? 2 * (1 - lifted / value) : 0
        return Color(hue: Double(hue), saturation: Double(valueSaturation), brightness: Double(value)).opacity(0.55)
    }
}

/// Browser tab row with favicon, unread state and a close affordance that
/// appears on hover, matching the interaction density of Arc and Edge.
private struct BrowserTabRow: View {
    let app: WebApp
    let selected: Bool
    let targeted: Bool
    let groupTint: Color?
    let icon: NSImage?
    let isRenaming: Bool
    let unread: Int?
    let closeLabel: String
    let mutedLabel: String
    let playingAudio: Bool
    let playingAudioLabel: String
    var onSelect: () -> Void
    var onFocusChange: (Bool) -> Void
    var onClose: () -> Void
    var onCommitRename: (String) -> Void
    var onCancelRename: () -> Void

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @FocusState private var rowFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            FaviconView(app: app, icon: icon, size: 16)
                .overlay(alignment: .topTrailing) {
                    if let unread {
                        UnreadBadge(count: unread)
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : Motion.badgePop, value: unread)
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .shadcnFocusRing(focused, cornerRadius: 6)
                    .onSubmit { onCommitRename(draft) }
                    .onExitCommand(perform: onCancelRename)
                    .onAppear { draft = app.displayName; focused = true }
            } else {
                Text(app.displayName)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.86)))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if app.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            if app.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(mutedLabel)
            }
            if playingAudio, !app.isMuted {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(playingAudioLabel)
                    .accessibilityLabel(playingAudioLabel)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(width: 20, height: 20)
                    .background(.primary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .help(closeLabel)
            .accessibilityLabel(closeLabel)
            .accessibilityHidden(!(hovering || selected))
            .allowsHitTesting(hovering || selected)
            .opacity(hovering || selected ? 1 : 0)
            .animation(
                reduceMotion ? nil : Motion.controlFeedback,
                value: hovering || selected
            )
        }
        .padding(6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    targeted
                        ? (groupTint?.opacity(0.18) ?? .primary.opacity(0.18))
                        : (selected
                            ? .primary.opacity(0.12)
                            : (hovering
                                ? (groupTint?.opacity(0.16) ?? .primary.opacity(0.07))
                                : .clear))
                )
        )
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(groupTint ?? .primary.opacity(0.58), lineWidth: 1.5 )
            }
        }
        .contentShape(Rectangle())
        .overlay { MiddleClickCloseRegion(onMiddleClick: onClose) }
        .focusable()
        .focused($rowFocused)
        .noFocusRing()
        .onChange(of: rowFocused) { _, value in onFocusChange(value) }
        .onHover { hovering = $0 }
        .onTapGesture {
            rowFocused = true
            onSelect()
        }
    }
}

/// Middle-click closes the tab, like Chrome's tab strip. The overlay claims
/// only middle-button hits (buttonNumber 2); left clicks and drags fall
/// through to the SwiftUI row beneath.
private struct MiddleClickCloseRegion: NSViewRepresentable {
    var onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickCloseNSView {
        MiddleClickCloseNSView()
    }

    func updateNSView(_ view: MiddleClickCloseNSView, context: Context) {
        view.onMiddleClick = onMiddleClick
    }
}

private final class MiddleClickCloseNSView: NSView {
    var onMiddleClick: () -> Void = {}

    /// `hitTest` carries no event, so inspect the one being dispatched: only
    /// claim the hit while a middle-button press is being routed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown, event.buttonNumber == 2 else { return nil }
        return super.hitTest(point)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick() }
    }
}

private struct UnreadBadge: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 3.5)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(.red))
            .overlay(Capsule().stroke(.black.opacity(0.12), lineWidth: 0.5))
            .contentTransition(.numericText(value: Double(count)))
            .animation(reduceMotion ? nil : Motion.badgePop, value: count)
            .fixedSize()
    }
}

/// Favicon (or monogram fallback) shared by the browser rail and Preferences.
struct FaviconView: View {
    let app: WebApp
    let icon: NSImage?
    var size: CGFloat = 32

    private var corner: CGFloat { size * 0.3 }

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
        } else {
            Text(app.monogram)
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: size, height: size)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }
}

struct AppTile: View {
    let app: WebApp
    let selected: Bool
    var targeted: Bool = false
    let icon: NSImage?

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FaviconView(app: app, icon: icon, size: 32)
            .frame(width: Theme.tile, height: Theme.tile)
            .background {
                RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                    .fill(.primary.opacity(targeted ? 0.16 : (hovering ? 0.07 : 0)))
            }
            .scaleEffect(selected ? 1.0 : 0.95)
            .animation(reduceMotion ? nil : Motion.tileSelection, value: selected)
            .onHover { hovering = $0 }
            .help(app.displayName)
    }
}
