import AppKit
import SwiftUI

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

    private var loc: Localized { settings.strings }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(IconButtonStyle())
                .help(loc.close)

                Text("\(model.workspaces.count) \(loc.spaces)")
                    .font(.system(size: 16, weight: .semibold))

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
                .help(loc.newWorkspace)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    ForEach(model.workspaces) { workspace in
                        SpaceCard(
                            workspace: workspace,
                            active: workspace.id == model.activeWorkspaceID,
                            icons: icons,
                            preview: previews[workspace.id],
                            hidePreview: workspace.id == hiddenPreviewID,
                            settings: settings,
                            onSelect: { onSelect(workspace.id) },
                            onPreviewFrameChange: { frame in onCardFrameChange(workspace.id, frame) }
                        )
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
            }
        }
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial)
        .transition(.opacity)
        .onExitCommand(perform: onClose)
    }
}

private struct SpaceCard: View {
    let workspace: Workspace
    let active: Bool
    let icons: IconStore
    let preview: NSImage?
    let hidePreview: Bool
    let settings: Settings
    var onSelect: () -> Void
    var onPreviewFrameChange: (CGRect) -> Void

    private var loc: Localized { settings.strings }
    private var title: String { workspace.name.isEmpty ? (workspace.isAgentOwned ? loc.defaultAgentWorkspace : loc.defaultWorkspace) : workspace.name }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
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
                }
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: SpacesMorph.cardPreviewCorner, style: .continuous))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("panel"))
                } action: { frame in
                    onPreviewFrameChange(frame)
                }

                HStack(spacing: 7) {
                    Image(systemName: workspace.isAgentOwned ? "sparkles" : workspace.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
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
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: active ? .primary.opacity(0.08) : nil,
            interactive: true
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(active ? Color.primary.opacity(0.38) : Color.clear, lineWidth: active ? 2 : 0)
        }
    }
}
