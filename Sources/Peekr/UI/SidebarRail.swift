import SwiftUI

/// The vertical icon dock. Reads the observable model directly so it
/// re-renders on add/select without manual wiring.
struct SidebarRail: View {
    let model: AppModel
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.apps) { app in
                Button {
                    onSelect(app.id)
                } label: {
                    AppTile(app: app, selected: app.id == model.selectedID)
                }
                .buttonStyle(.plain)
                .help(app.title)
            }

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help("Add web app")

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AppTile: View {
    let app: WebApp
    let selected: Bool

    var body: some View {
        Text(app.monogram)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(tileColor, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .scaleEffect(selected ? 1.0 : 0.96)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }

    /// Stable colour derived from the URL (FNV-ish) so tiles keep their hue
    /// across launches — Swift's String.hashValue is per-process randomised.
    private var tileColor: Color {
        var hash = 5381
        for byte in app.urlString.utf8 { hash = (hash &* 33) &+ Int(byte) }
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.78)
    }
}
