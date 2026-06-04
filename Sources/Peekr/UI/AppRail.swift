import SwiftUI

/// The vertical dock of web-app icons. Floating rounded favicons (no tile box),
/// drag-to-reorder, right-click menu. Active = a left indicator bar only.
/// Empty rail space is transparent so it falls through to the window-drag layer.
struct AppRail: View {
    let model: AppModel
    let settings: Settings
    let icons: IconStore
    var onSelect: (UUID) -> Void
    var onAdd: () -> Void
    var onEdit: (WebApp) -> Void

    @State private var dropTarget: UUID?

    private var loc: Localized { settings.strings }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 8)
            GlassGroup(spacing: 14) {
                ForEach(model.apps) { app in
                    tile(for: app)
                }
            }
            addButton
            Spacer(minLength: 8)
        }
        .frame(width: Theme.railWidth)
        .frame(maxHeight: .infinity)
    }

    private func tile(for app: WebApp) -> some View {
        AppTile(app: app, selected: app.id == model.selectedID,
                targeted: dropTarget == app.id, icon: icons.image(for: app))
            .overlay(alignment: .leading) { selectionIndicator(app) }
            .contentShape(RoundedRectangle(cornerRadius: Theme.tileCorner))
            .onTapGesture { onSelect(app.id) }
            .draggable(app.id.uuidString) {
                AppTile(app: app, selected: true, targeted: false, icon: icons.image(for: app))
                    .frame(width: Theme.tile, height: Theme.tile)
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
                Button { onSelect(app.id) } label: { Label(loc.open, systemImage: "arrow.up.forward.app") }
                Button { icons.refreshFavicon(app) } label: { Label(loc.refreshIcon, systemImage: "arrow.clockwise") }
                Divider()
                Button(role: .destructive) { model.removeApp(app.id) } label: {
                    Label(loc.delete, systemImage: "trash")
                }
            }
    }

    /// Active state: a single left-edge bar — no surrounding border.
    @ViewBuilder
    private func selectionIndicator(_ app: WebApp) -> some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 3, height: app.id == model.selectedID ? 26 : 0)
            .offset(x: -10)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.selectedID)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.tile, height: Theme.tile)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(loc.addWebApp)
    }
}

/// A single dock entry: a centered, rounded "app-icon" favicon. No tile box —
/// selection is shown by the rail's left bar, hover by a faint backing.
struct AppTile: View {
    let app: WebApp
    let selected: Bool
    var targeted: Bool = false
    let icon: NSImage?

    @State private var hovering = false

    var body: some View {
        iconView
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

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: Theme.iconCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.iconCorner, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
        } else {
            Text(app.monogram)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.iconCorner, style: .continuous))
        }
    }
}
