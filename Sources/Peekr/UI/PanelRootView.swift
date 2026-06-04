import SwiftUI

/// The whole panel: a frosted shell holding the icon rail and an inset web
/// "card" with a floating omnibox above it. Resize handles live on the free
/// inner edges. Monochrome / shadcn — restraint over colour.
struct PanelRootView: View {
    let model: AppModel
    let settings: Settings
    let manager: WebViewManager
    let icons: IconStore

    var onMoveBegan: () -> Void
    var onMoveChanged: (CGSize) -> Void
    var onMoveEnded: () -> Void
    var onModalChange: (Bool) -> Void
    var onResizeBegan: () -> Void
    var onResizeChanged: (PanelResizeEdge, CGSize) -> Void
    var onResizeEnded: () -> Void

    @State private var editTarget: EditTarget?
    @State private var moving = false

    /// Initial root for the hosting view before the controller wires callbacks.
    static func placeholder(model: AppModel, settings: Settings, manager: WebViewManager, icons: IconStore) -> PanelRootView {
        PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons,
            onMoveBegan: {}, onMoveChanged: { _ in }, onMoveEnded: {}, onModalChange: { _ in },
            onResizeBegan: {}, onResizeChanged: { _, _ in }, onResizeEnded: {}
        )
    }

    private var anchor: PanelAnchor { settings.anchor }
    private var widthEdge: PanelResizeEdge { anchor.isRightSide ? .leading : .trailing }
    private var heightEdge: PanelResizeEdge { anchor.isTopSide ? .bottom : .top }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !moving { moving = true; onMoveBegan() }
                onMoveChanged(value.translation)
            }
            .onEnded { _ in moving = false; onMoveEnded() }
    }

    var body: some View {
        ZStack {
            PanelBackground()
            // The whole frosted background is a drag handle. Dragging just moves
            // the window freely (no edge detection); snapping happens on release.
            Color.clear
                .contentShape(Rectangle())
                .gesture(moveGesture)
            HStack(spacing: 0) {
                if anchor.railOnLeft {
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
                .stroke(Theme.hairline, lineWidth: 1)
        }
        .overlay(alignment: widthEdge == .leading ? .leading : .trailing) {
            ResizeHandle(edge: widthEdge, hint: settings.strings.resizeHint,
                         onBegan: onResizeBegan, onChanged: onResizeChanged, onEnded: onResizeEnded)
        }
        .overlay(alignment: heightEdge == .top ? .top : .bottom) {
            ResizeHandle(edge: heightEdge, hint: settings.strings.resizeHint,
                         onBegan: onResizeBegan, onChanged: onResizeChanged, onEnded: onResizeEnded)
        }
        .ignoresSafeArea()
        .sheet(item: $editTarget) { target in
            EditAppSheet(target: target, model: model, settings: settings, icons: icons) { editTarget = nil }
        }
        .onChange(of: editTarget != nil) { _, open in onModalChange(open) }
        .animation(.smooth(duration: 0.3), value: anchor.railOnLeft)
    }

    private var rail: some View {
        AppRail(
            model: model, settings: settings, icons: icons,
            onSelect: { id in manager.activate(id); model.select(id) },
            onAdd: { editTarget = EditTarget(app: nil) },
            onEdit: { editTarget = EditTarget(app: $0) }
        )
    }

    private var webArea: some View {
        ZStack(alignment: .top) {
            WebContainer(manager: manager, currentID: manager.state.currentID)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                .padding(.top, 50)
                .padding([.bottom, .horizontal], 10)

            NavigationBar(
                state: manager.state, manager: manager, settings: settings,
                onMoveBegan: onMoveBegan, onMoveChanged: onMoveChanged, onMoveEnded: onMoveEnded
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Clean neutral backdrop. Translucency comes from the window's visual-effect
/// view; this adds only a faint top highlight for depth.
struct PanelBackground: View {
    var body: some View {
        LinearGradient(
            colors: [.white.opacity(0.05), .clear],
            startPoint: .top, endPoint: .center
        )
        .allowsHitTesting(false)
    }
}

/// A draggable resize strip on one free edge of the panel.
private struct ResizeHandle: View {
    let edge: PanelResizeEdge
    let hint: String
    var onBegan: () -> Void
    var onChanged: (PanelResizeEdge, CGSize) -> Void
    var onEnded: () -> Void

    @State private var active = false
    @State private var hovering = false

    private var isVertical: Bool { edge == .leading || edge == .trailing }

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(active || hovering ? 0.08 : 0.001))
            .frame(width: isVertical ? 10 : nil, height: isVertical ? nil : 10)
            .overlay(grabber)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
                else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !active { active = true; onBegan() }
                        onChanged(edge, value.translation)
                    }
                    .onEnded { _ in active = false; onEnded() }
            )
            .help(hint)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.primary.opacity(active || hovering ? 0.4 : 0.22))
            .frame(width: isVertical ? 3 : 30, height: isVertical ? 30 : 3)
    }
}
