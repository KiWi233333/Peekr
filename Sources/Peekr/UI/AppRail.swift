import SwiftUI

/// The vertical dock of web-app icons. Rounded favicons, drag-to-reorder,
/// right-click context menu, monochrome selection. The icon group is centered.
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
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    GlassGroup(spacing: 14) {
                        ForEach(model.apps) { app in
                            tile(for: app)
                        }
                    }
                    addButton
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .frame(width: Theme.railWidth)
    }

    private func tile(for app: WebApp) -> some View {
        AppTile(app: app, selected: app.id == model.selectedID, icon: icons.image(for: app))
            .overlay(alignment: .leading) { selectionIndicator(app) }
            .contentShape(RoundedRectangle(cornerRadius: Theme.tileCorner))
            .onTapGesture { onSelect(app.id) }
            .draggable(app.id.uuidString) {
                AppTile(app: app, selected: true, icon: icons.image(for: app))
                    .frame(width: Theme.tile, height: Theme.tile)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
                withAnimation(.snappy) { model.move(dragged, before: app.id) }
                return true
            } isTargeted: { targeted in
                dropTarget = targeted ? app.id : (dropTarget == app.id ? nil : dropTarget)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                    .stroke(Color.primary, lineWidth: 1.5)
                    .opacity(dropTarget == app.id ? 0.9 : 0)
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

    @ViewBuilder
    private func selectionIndicator(_ app: WebApp) -> some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 3, height: app.id == model.selectedID ? 24 : 0)
            .offset(x: -8)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.selectedID)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.tile, height: Theme.tile)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .help(loc.addWebApp)
    }
}

/// A single dock tile: a centered, rounded favicon (or monogram) on a glass square.
struct AppTile: View {
    let app: WebApp
    let selected: Bool
    let icon: NSImage?

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.iconCorner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.iconCorner, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 0.5)
                    }
            } else {
                Text(app.monogram)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.iconCorner, style: .continuous))
            }
        }
        .frame(width: Theme.tile, height: Theme.tile)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous),
            interactive: true
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                .stroke(Color.primary.opacity(selected ? 0.85 : 0), lineWidth: 1.5)
        }
        .scaleEffect(selected ? 1.0 : 0.92)
        .shadow(color: .black.opacity(selected ? 0.2 : 0.1), radius: selected ? 4 : 2, y: 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selected)
        .help(app.title)
    }
}
