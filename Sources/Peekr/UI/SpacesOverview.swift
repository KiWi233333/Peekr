import AppKit
import SwiftUI
import Inject

/// A lightweight Space switcher inspired by ego-lite's overview. It stays in
/// the panel so switching spaces never creates a second window or loses the
/// current browser session.
struct SpacesOverview: View {
    let model: AppModel
    let settings: Settings
    let icons: IconStore
    let previews: [UUID: NSImage]
    /// Workspace whose card preview is being carried by the morph layer; its
    /// in-grid image stays hidden until the flight completes.
    var hiddenPreviewID: UUID?
    var onSelect: (UUID) -> Void
    var onNewWorkspace: () -> Void
    var onNewAgentWorkspace: () -> Void
    var onClose: () -> Void
    var onCardFrameChange: (UUID, CGRect) -> Void

    @State private var dropTargetID: UUID?
    @State private var renameTargetID: UUID?
    @State private var renameDraft = ""
    @ObserveInjection private var inject

    private var loc: Localized { settings.strings }

    var body: some View {
        let orderedWorkspaces = model.orderedWorkspaces

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(IconButtonStyle())
                .help(loc.close)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(orderedWorkspaces.count) \(loc.spaces)")
                        .font(.system(size: 16, weight: .semibold))
                    Text(loc.reorderWorkspaces)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Menu {
                    Button(action: onNewWorkspace) {
                        Label(loc.newWorkspace, systemImage: "plus")
                    }
                    Button(action: onNewAgentWorkspace) {
                        Label(loc.newAgentWorkspace, systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(loc.newWorkspace)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    ForEach(orderedWorkspaces) { workspace in
                        workspaceCard(workspace)
                    }
                    Button(action: onNewWorkspace) {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 26, weight: .medium))
                            Text(loc.newWorkspace)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 156)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .dropDestination(for: String.self) { items, _ in
                    handleWorkspaceDrop(items, before: nil)
                }
            }
        }
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial)
        .transition(.opacity)
        .onExitCommand(perform: onClose)
        .alert(loc.rename, isPresented: Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )) {
            TextField(loc.defaultWorkspace, text: $renameDraft)
            Button(loc.cancel, role: .cancel) { renameTargetID = nil }
            Button(loc.save) {
                if let renameTargetID {
                    model.renameWorkspace(renameTargetID, to: renameDraft)
                }
                self.renameTargetID = nil
            }
        }
        .enableInjection()
    }

    @ViewBuilder
    private func workspaceCard(_ workspace: Workspace) -> some View {
        let workspaceID = workspace.id
        SpaceCard(
            workspace: workspace,
            active: workspaceID == model.activeWorkspaceID,
            icons: icons,
            preview: previews[workspaceID],
            hidePreview: workspaceID == hiddenPreviewID,
            settings: settings,
            canDelete: model.workspaces.count > 1,
            dropTargeted: dropTargetID == workspaceID,
            onSelect: { onSelect(workspaceID) },
            onRename: {
                renameDraft = workspace.name
                renameTargetID = workspaceID
            },
            onTogglePin: { model.toggleWorkspacePin(workspaceID) },
            onTakeOver: { model.takeOverWorkspace(workspaceID) },
            onDelete: { model.removeWorkspace(workspaceID) },
            onMoveWorkspace: { draggedID, targetID in
                _ = handleWorkspaceDrop([draggedID.uuidString], before: targetID)
            },
            onTargetChange: { targetID in dropTargetID = targetID },
            onPreviewFrameChange: { frame in onCardFrameChange(workspaceID, frame) }
        )
    }

    private func handleWorkspaceDrop(_ items: [String], before referenceID: UUID?) -> Bool {
        guard let rawID = items.first,
              let draggedID = UUID(uuidString: rawID),
              model.workspaces.contains(where: { $0.id == draggedID }),
              draggedID != referenceID else { return false }

        withAnimation(Motion.reduceMotion ? nil : Motion.sidebarReorder) {
            model.moveWorkspace(draggedID, before: referenceID)
        }
        dropTargetID = nil
        return true
    }
}

private struct SpaceCard: View {
    let workspace: Workspace
    let active: Bool
    let icons: IconStore
    let preview: NSImage?
    let hidePreview: Bool
    let settings: Settings
    let canDelete: Bool
    let dropTargeted: Bool
    var onSelect: () -> Void
    var onRename: () -> Void
    var onTogglePin: () -> Void
    var onTakeOver: () -> Void
    var onDelete: () -> Void
    var onMoveWorkspace: (UUID, UUID) -> Void
    var onTargetChange: (UUID?) -> Void
    var onPreviewFrameChange: (CGRect) -> Void

    @State private var isHovered = false

    private var loc: Localized { settings.strings }
    private var title: String { workspace.name.isEmpty ? (workspace.isAgentOwned ? loc.defaultAgentWorkspace : loc.defaultWorkspace) : workspace.name }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 10) {
                    previewContent
                    HStack(spacing: 7) {
                        Image(systemName: workspace.isAgentOwned ? "sparkles" : workspace.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        if workspace.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tint)
                                .accessibilityLabel(loc.pinWorkspace)
                        }
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(workspace.tabs.count)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            cardMenu
                .padding(10)
                .opacity(isHovered || dropTargeted ? 1 : 0.82)
        }
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: active ? .primary.opacity(0.08) : nil,
            interactive: true
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    dropTargeted ? Color.accentColor : active ? Color.primary.opacity(0.38) : Color.clear,
                    lineWidth: dropTargeted ? 3 : active ? 2 : 0
                )
        }
        .shadow(color: dropTargeted ? Color.accentColor.opacity(0.24) : .clear, radius: 10)
        .onHover { isHovered = $0 }
        .contextMenu { actionItems }
        .draggable(workspace.id.uuidString) {
            Label(title, systemImage: workspace.isAgentOwned ? "sparkles" : workspace.symbol)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first,
                  let draggedID = UUID(uuidString: rawID),
                  draggedID != workspace.id else { return false }
            // The parent model keeps pinned and unpinned sections stable.
            onMoveWorkspace(draggedID, workspace.id)
            return true
        } isTargeted: { targeted in
            onTargetChange(targeted ? workspace.id : nil)
        }
        .pointerCursor(.openHand)
    }

    private var previewContent: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: SpacesMorph.cardPreviewCorner, style: .continuous)
                .fill(.primary.opacity(0.055))
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .opacity(hidePreview ? 0 : 0.9)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(workspace.tabs.prefix(3))) { tab in
                        HStack(spacing: 7) {
                            if let image = icons.image(for: tab) {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: 14, height: 14)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            } else {
                                Image(systemName: "globe")
                                    .font(.system(size: 12))
                                    .frame(width: 14, height: 14)
                                    .foregroundStyle(.secondary)
                            }
                            Text(tab.displayName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if workspace.tabs.isEmpty {
                        Image(systemName: workspace.isAgentOwned ? "sparkles" : workspace.symbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            if isHovered {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .background(.thinMaterial, in: Circle())
                    .padding(8)
                    .accessibilityLabel(loc.reorderWorkspaces)
            }
        }
        .frame(height: 112)
        .clipShape(RoundedRectangle(cornerRadius: SpacesMorph.cardPreviewCorner, style: .continuous))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("panel"))
        } action: { frame in
            onPreviewFrameChange(frame)
        }
    }

    private var cardMenu: some View {
        Menu { actionItems } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(loc.moreActions)
        .accessibilityLabel(loc.moreActions)
    }

    @ViewBuilder
    private var actionItems: some View {
        Button(action: onSelect) {
            Label(loc.open, systemImage: "arrow.up.forward.app")
        }
        Divider()
        Button(action: onRename) {
            Label(loc.rename, systemImage: "pencil")
        }
        Button(action: onTogglePin) {
            Label(
                workspace.isPinned ? loc.unpinWorkspace : loc.pinWorkspace,
                systemImage: workspace.isPinned ? "pin.slash" : "pin"
            )
        }
        if workspace.isAgentOwned {
            Button(action: onTakeOver) {
                Label(loc.takeOverWorkspace, systemImage: "hand.tap")
            }
        }
        if canDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(loc.delete, systemImage: "trash")
            }
        }
    }

}
