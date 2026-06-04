import SwiftUI

/// The whole panel: a frosted glass shell holding the icon rail and an inset
/// web "card" with a floating glass omnibox above it.
struct PanelRootView: View {
    let model: AppModel
    let settings: Settings
    let manager: WebViewManager
    let icons: IconStore

    var onMoveBegan: () -> Void
    var onMoveChanged: (CGSize) -> Void
    var onMoveEnded: () -> Void
    var onModalChange: (Bool) -> Void

    @State private var editTarget: EditTarget?

    var body: some View {
        ZStack {
            PanelBackground()
            HStack(spacing: 0) {
                if settings.anchor.railOnLeft {
                    rail
                    webArea
                } else {
                    webArea
                    rail
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .ignoresSafeArea()
        .sheet(item: $editTarget) { target in
            EditAppSheet(target: target, model: model, icons: icons) { editTarget = nil }
        }
        .onChange(of: editTarget != nil) { _, open in onModalChange(open) }
        .animation(.smooth(duration: 0.3), value: settings.anchor.railOnLeft)
    }

    private var rail: some View {
        AppRail(
            model: model,
            icons: icons,
            onSelect: { id in manager.activate(id); model.select(id) },
            onAdd: { editTarget = EditTarget(app: nil) },
            onEdit: { editTarget = EditTarget(app: $0) }
        )
    }

    private var webArea: some View {
        ZStack(alignment: .top) {
            WebContainer(manager: manager, currentID: manager.state.currentID)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.black.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
                .padding(.top, 52)
                .padding([.bottom, .horizontal], 11)

            NavigationBar(
                state: manager.state,
                manager: manager,
                onMoveBegan: onMoveBegan,
                onMoveChanged: onMoveChanged,
                onMoveEnded: onMoveEnded
            )
            .padding(.horizontal, 13)
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Atmospheric backdrop — translucency comes from the window's NSVisualEffectView;
/// these are just the aqua "liquid" glows + a top highlight.
struct PanelBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.white.opacity(0.06), .clear],
                startPoint: .top, endPoint: .center
            )
            RadialGradient(
                colors: [Theme.accent.opacity(0.22), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 360
            )
            RadialGradient(
                colors: [Theme.accentDeep.opacity(0.18), .clear],
                center: .bottomLeading, startRadius: 0, endRadius: 440
            )
        }
        .allowsHitTesting(false)
    }
}
