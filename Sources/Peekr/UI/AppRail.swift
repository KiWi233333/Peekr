import SwiftUI

/// The vertical dock of web-app icons. Glass tiles, drag-to-reorder,
/// right-click context menu, favicons with monogram fallback.
struct AppRail: View {
    let model: AppModel
    let icons: IconStore
    var onSelect: (UUID) -> Void
    var onAdd: () -> Void
    var onEdit: (WebApp) -> Void

    @State private var dropTarget: UUID?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                GlassGroup(spacing: 16) {
                    ForEach(model.apps) { app in
                        tile(for: app)
                    }
                }
                addButton
                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
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
                    .stroke(Theme.accent, lineWidth: 2)
                    .opacity(dropTarget == app.id ? 1 : 0)
            }
            .contextMenu {
                Button { onEdit(app) } label: { Label("Edit…", systemImage: "pencil") }
                Button { onSelect(app.id) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                Button { icons.refreshFavicon(app) } label: { Label("Refresh Icon", systemImage: "arrow.clockwise") }
                Divider()
                Button(role: .destructive) { model.removeApp(app.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private func selectionIndicator(_ app: WebApp) -> some View {
        Capsule()
            .fill(Theme.accentGradient)
            .frame(width: 3.5, height: app.id == model.selectedID ? 26 : 0)
            .offset(x: -9)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.selectedID)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.tile, height: Theme.tile)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .help("Add web app")
    }
}

/// A single dock tile: favicon or monogram on a glass square.
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
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
            } else {
                Text(app.monogram)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(monogramColor)
            }
        }
        .frame(width: Theme.tile, height: Theme.tile)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous),
            tint: selected ? Theme.accent.opacity(0.55) : nil,
            interactive: true
        )
        .scaleEffect(selected ? 1.0 : 0.93)
        .shadow(color: .black.opacity(selected ? 0.22 : 0.12), radius: selected ? 5 : 2, y: 1.5)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selected)
        .help(app.title)
    }

    private var monogramColor: Color {
        var hash = 5381
        for byte in app.urlString.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return Color(hue: Double(abs(hash) % 360) / 360.0, saturation: 0.6, brightness: 0.92)
    }
}
