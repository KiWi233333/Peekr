import SwiftUI

/// The whole panel: a frosted shell holding the icon rail and an inset web
/// "card" with a floating omnibox above it. Resize handles live on the free
/// inner edges. Monochrome / shadcn — restraint over colour.
struct PanelRootView: View {
    let model: AppModel
    let settings: Settings
    let manager: WebViewManager
    let icons: IconStore
    let bookmarks: BookmarksModel

    var onMoveBegan: () -> Void
    var onMoveChanged: (CGSize) -> Void
    var onMoveEnded: () -> Void
    var onModalChange: (Bool) -> Void
    var onResizeBegan: () -> Void
    var onResizeChanged: ([PanelResizeEdge], CGSize) -> Void
    var onResizeEnded: () -> Void

    @State private var editTarget: EditTarget?
    @State private var bookmarksOpen = false
    @State private var moving = false

    /// Initial root for the hosting view before the controller wires callbacks.
    static func placeholder(model: AppModel, settings: Settings, manager: WebViewManager, icons: IconStore, bookmarks: BookmarksModel) -> PanelRootView {
        PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons, bookmarks: bookmarks,
            onMoveBegan: {}, onMoveChanged: { _ in }, onMoveEnded: {}, onModalChange: { _ in },
            onResizeBegan: {}, onResizeChanged: { _, _ in }, onResizeEnded: {}
        )
    }

    private var isModalOpen: Bool { editTarget != nil || bookmarksOpen }
    private var anchor: PanelAnchor { settings.anchor }

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
        // Native-style resize border on the panel's free edges + corner.
        .overlay {
            ResizeBorder(zones: anchor.resizeZones, hint: settings.strings.resizeHint,
                         onBegan: onResizeBegan, onChanged: onResizeChanged, onEnded: onResizeEnded)
        }
        .ignoresSafeArea()
        .sheet(item: $editTarget) { target in
            EditAppSheet(target: target, model: model, settings: settings, icons: icons) { editTarget = nil }
        }
        .sheet(isPresented: $bookmarksOpen) {
            BookmarkSheet(
                bookmarks: bookmarks, settings: settings,
                onOpen: { manager.loadAddress($0); bookmarksOpen = false },
                onClose: { bookmarksOpen = false }
            )
        }
        .onChange(of: editTarget != nil) { _, _ in onModalChange(isModalOpen) }
        .onChange(of: bookmarksOpen) { _, _ in onModalChange(isModalOpen) }
        .animation(.smooth(duration: 0.3), value: anchor.railOnLeft)
    }

    private var rail: some View {
        AppRail(
            model: model, settings: settings, icons: icons,
            onSelect: { id in manager.activate(id); model.select(id) },
            onAdd: { editTarget = EditTarget(app: nil) },
            onEdit: { editTarget = EditTarget(app: $0) },
            onWorkspaceSwitched: {
                // Re-point the web area at the new workspace's active tab.
                if let id = model.selectedID {
                    manager.activate(id)
                    model.select(id)
                } else {
                    manager.state.currentID = nil
                }
            }
        )
    }

    private var webArea: some View {
        ZStack(alignment: .top) {
            WebContainer(manager: manager, currentID: manager.state.currentID)
                .clipShape(RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                .padding(.top, 50)
                .padding([.bottom, .horizontal], 10)

            NavigationBar(
                state: manager.state, manager: manager, settings: settings,
                model: model, bookmarks: bookmarks,
                onMoveBegan: onMoveBegan, onMoveChanged: onMoveChanged, onMoveEnded: onMoveEnded,
                onBookmarks: { bookmarksOpen = true }
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

/// Native-style resize border: near-invisible hit-zones along the panel's free
/// edges + corner. A real macOS window shows no visible grab — just the resize
/// cursor — so these stay transparent at rest and light up only faintly on
/// hover/drag. Docked edges have no zone (they stay flush to the screen).
private struct ResizeBorder: View {
    let zones: [PanelResizeZone]
    let hint: String
    var onBegan: () -> Void
    var onChanged: ([PanelResizeEdge], CGSize) -> Void
    var onEnded: () -> Void

    var body: some View {
        ZStack {
            // `zones` lists the corner last, so it stacks above the edge zones
            // and wins the pixels they share at the corner.
            ForEach(zones, id: \.self) { zone in
                ResizeZoneHandle(zone: zone, hint: hint,
                                 onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
            }
        }
    }
}

/// One resize zone — a thin edge band or a corner square — positioned on the
/// panel's perimeter and carrying the matching native resize cursor.
private struct ResizeZoneHandle: View {
    let zone: PanelResizeZone
    let hint: String
    var onBegan: () -> Void
    var onChanged: ([PanelResizeEdge], CGSize) -> Void
    var onEnded: () -> Void

    @State private var active = false
    @State private var hovering = false

    private static let edgeThickness: CGFloat = 8
    private static let cornerSize: CGFloat = 18

    var body: some View {
        // Size + hit-test the zone first, THEN position it. The fill axis (nil
        // dimension) stretches to the panel edge; contentShape/gestures bind to
        // this sized band — never the full-panel positioning frame below, or the
        // zone would swallow hits across the whole panel.
        Color.primary.opacity(active || hovering ? 0.06 : 0.001)
            .frame(width: fixedWidth, height: fixedHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { cursor.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !active { active = true; onBegan() }
                        onChanged(edges, value.translation)
                    }
                    .onEnded { _ in active = false; onEnded() }
            )
            .help(hint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    // The zone's fixed dimension(s); the other axis fills the panel edge.
    private var fixedWidth: CGFloat? {
        switch zone {
        case .edge(.leading), .edge(.trailing): return Self.edgeThickness
        case .edge(.top), .edge(.bottom):       return nil
        case .corner:                           return Self.cornerSize
        }
    }
    private var fixedHeight: CGFloat? {
        switch zone {
        case .edge(.top), .edge(.bottom):       return Self.edgeThickness
        case .edge(.leading), .edge(.trailing): return nil
        case .corner:                           return Self.cornerSize
        }
    }
    private var alignment: Alignment {
        switch zone {
        case .edge(.leading):  return .leading
        case .edge(.trailing): return .trailing
        case .edge(.top):      return .top
        case .edge(.bottom):   return .bottom
        case .corner(let h, let v):
            return Alignment(horizontal: h == .leading ? .leading : .trailing,
                             vertical: v == .top ? .top : .bottom)
        }
    }
    private var edges: [PanelResizeEdge] {
        switch zone {
        case .edge(let e):          return [e]
        case .corner(let h, let v): return [h, v]
        }
    }
    private var cursor: NSCursor {
        switch zone {
        case .edge(.leading), .edge(.trailing): return .resizeLeftRight
        case .edge(.top), .edge(.bottom):       return .resizeUpDown
        case .corner(let h, let v):
            // NE–SW corners (top-right / bottom-left) vs NW–SE (top-left / bottom-right).
            let neSW = (h == .trailing && v == .top) || (h == .leading && v == .bottom)
            return neSW ? Self.diagNESW : Self.diagNWSE
        }
    }

    // AppKit ships no public diagonal-resize cursor, so build them from SF
    // Symbols once (falling back to crosshair if unavailable).
    private static let diagNESW = makeDiagonalCursor("arrow.up.right.and.arrow.down.left")
    private static let diagNWSE = makeDiagonalCursor("arrow.up.left.and.arrow.down.right")
    private static func makeDiagonalCursor(_ symbol: String) -> NSCursor {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return .crosshair }
        return NSCursor(image: img, hotSpot: NSPoint(x: img.size.width / 2, y: img.size.height / 2))
    }
}
