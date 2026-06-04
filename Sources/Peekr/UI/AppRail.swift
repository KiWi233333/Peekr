import AppKit
import SwiftUI

/// Left sidebar: a workspace switcher above a vertical list of the active
/// workspace's tabs. Tabs show icon + name, reorder by drag, and rename inline
/// (double-click). Workspace ops go straight to `model`; `onWorkspaceSwitched`
/// lets the panel re-point the web area at the newly active tab.
struct AppRail: View {
    let model: AppModel
    let settings: Settings
    let icons: IconStore
    var onSelect: (UUID) -> Void
    var onAdd: () -> Void
    var onEdit: (WebApp) -> Void
    var onWorkspaceSwitched: () -> Void

    @State private var dropTarget: UUID?
    @State private var renamingTab: UUID?
    @State private var renamingWorkspace: UUID?
    @State private var workspaceDraft = ""
    @FocusState private var workspaceFieldFocused: Bool

    private var loc: Localized { settings.strings }

    var body: some View {
        VStack(spacing: 8) {
            workspaceBar
            Divider().opacity(0.4).padding(.horizontal, 10)
            tabList
            addTabButton
        }
        .padding(.vertical, 10)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Workspace switcher

    private var workspaceBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                if renamingWorkspace == model.activeWorkspaceID {
                    TextField(loc.defaultWorkspace, text: $workspaceDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .focused($workspaceFieldFocused)
                        .onSubmit(commitRenameWorkspace)
                        .onExitCommand { renamingWorkspace = nil }
                } else {
                    Text(displayName(model.activeWorkspace))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginRenameWorkspace(model.activeWorkspace) }
                }
                Spacer(minLength: 4)
                Button { model.addWorkspace(); onWorkspaceSwitched() } label: {
                    Image(systemName: "plus.square.on.square").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(.secondary)
                .help(loc.newWorkspace)
            }

            if model.workspaces.count > 1 {
                HStack(spacing: 5) {
                    ForEach(model.workspaces) { workspace in chip(workspace) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func chip(_ workspace: Workspace) -> some View {
        let active = workspace.id == model.activeWorkspaceID
        return Button { model.selectWorkspace(workspace.id); onWorkspaceSwitched() } label: {
            Text(chipLabel(workspace))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(minWidth: 22, minHeight: 18)
                .padding(.horizontal, 4)
                .background(Capsule().fill(active ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.primary.opacity(0.1))))
                .foregroundStyle(active ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(displayName(workspace))
        .contextMenu {
            Button { beginRenameWorkspace(workspace) } label: { Label(loc.rename, systemImage: "pencil") }
            if model.workspaces.count > 1 {
                Button(role: .destructive) { model.removeWorkspace(workspace.id); onWorkspaceSwitched() } label: {
                    Label(loc.delete, systemImage: "trash")
                }
            }
        }
    }

    private func displayName(_ workspace: Workspace) -> String {
        workspace.name.isEmpty ? loc.defaultWorkspace : workspace.name
    }

    private func chipLabel(_ workspace: Workspace) -> String {
        if let first = workspace.name.first { return String(first).uppercased() }
        let index = model.workspaces.firstIndex { $0.id == workspace.id } ?? 0
        return "\(index + 1)"
    }

    private func beginRenameWorkspace(_ workspace: Workspace) {
        if workspace.id != model.activeWorkspaceID { model.selectWorkspace(workspace.id); onWorkspaceSwitched() }
        workspaceDraft = workspace.name
        renamingWorkspace = workspace.id
        workspaceFieldFocused = true
    }

    private func commitRenameWorkspace() {
        if let id = renamingWorkspace {
            model.renameWorkspace(id, to: workspaceDraft.trimmingCharacters(in: .whitespaces))
        }
        renamingWorkspace = nil
    }

    // MARK: - Tabs

    private var tabList: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(model.apps) { app in tabRow(app) }
            }
            .padding(.horizontal, 8)
        }
    }

    private func tabRow(_ app: WebApp) -> some View {
        TabRow(
            app: app,
            selected: app.id == model.selectedID,
            targeted: dropTarget == app.id,
            icon: icons.image(for: app),
            isRenaming: renamingTab == app.id,
            displayTitle: app.title.isEmpty ? (app.host ?? app.urlString) : app.title,
            onSelect: { if renamingTab == nil { onSelect(app.id) } },
            onCommitRename: { model.rename(app.id, to: $0.trimmingCharacters(in: .whitespaces)); renamingTab = nil },
            onCancelRename: { renamingTab = nil }
        )
        .draggable(app.id.uuidString) {
            FaviconView(app: app, icon: icons.image(for: app), size: Theme.tile)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
            withAnimation(.snappy) { model.move(dragged, before: app.id) }
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? app.id : (dropTarget == app.id ? nil : dropTarget)
        }
        .contextMenu {
            Button { onEdit(app) } label: { Label(loc.edit, systemImage: "pencil") }
            Button { renamingTab = app.id } label: { Label(loc.rename, systemImage: "character.cursor.ibeam") }
            Button { onSelect(app.id) } label: { Label(loc.open, systemImage: "arrow.up.forward.app") }
            Button {
                icons.refresh(app) { model.rename(app.id, to: $0) }
            } label: { Label(loc.refreshIconAndTitle, systemImage: "arrow.clockwise") }
            Divider()
            Button(role: .destructive) { model.removeApp(app.id) } label: { Label(loc.delete, systemImage: "trash") }
        }
    }

    private var addTabButton: some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text(loc.newTab).font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help(loc.newTab)
    }
}

/// One row in the tab sidebar: favicon + name, with inline rename, hover tint
/// and a left selection bar.
private struct TabRow: View {
    let app: WebApp
    let selected: Bool
    let targeted: Bool
    let icon: NSImage?
    let isRenaming: Bool
    let displayTitle: String
    var onSelect: () -> Void
    var onCommitRename: (String) -> Void
    var onCancelRename: () -> Void

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            FaviconView(app: app, icon: icon, size: 22)
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { onCommitRename(draft) }
                    .onExitCommand(perform: onCancelRename)
                    .onAppear { draft = app.title; focused = true }
            } else {
                Text(displayTitle)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                .fill(.primary.opacity(targeted ? 0.16 : (selected ? 0.10 : (hovering ? 0.05 : 0))))
        )
        .overlay(alignment: .leading) {
            Capsule().fill(Color.primary)
                .frame(width: 3, height: selected ? 16 : 0)
                .offset(x: -4)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Favicon (or monogram fallback) for a web app, rounded like an app icon.
/// Shared by the tab sidebar and the Preferences list so icon rendering lives
/// in one place.
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

/// A single dock entry used in Preferences: a centered, rounded favicon with a
/// faint hover/selection backing.
struct AppTile: View {
    let app: WebApp
    let selected: Bool
    var targeted: Bool = false
    let icon: NSImage?

    @State private var hovering = false

    var body: some View {
        FaviconView(app: app, icon: icon, size: 32)
            .frame(width: Theme.tile, height: Theme.tile)
            .background {
                RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                    .fill(.primary.opacity(targeted ? 0.16 : (hovering ? 0.07 : 0)))
            }
            .scaleEffect(selected ? 1.0 : 0.95)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selected)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .help(app.title)
    }
}
