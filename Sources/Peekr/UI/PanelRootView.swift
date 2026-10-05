import SwiftUI
import Inject

/// The whole panel: a frosted shell holding the icon rail and an inset web
/// "card" with a floating omnibox above it. Resize handles live on the free
/// inner edges. Monochrome / shadcn — restraint over colour.
struct PanelRootView: View {
    let model: AppModel
    let settings: Settings
    let manager: WebViewManager
    let icons: IconStore
    let badges: BadgeStore
    let bookmarks: BookmarksModel

    var onMoveBegan: () -> Void
    var onMoveChanged: (CGSize) -> Void
    var onMoveEnded: () -> Void
    var onModalChange: (Bool) -> Void
    var onTabFocusChange: (Bool) -> Void
    var onResizeBegan: () -> Void
    var onResizeChanged: ([PanelResizeEdge]) -> Void
    var onResizeEnded: () -> Void

    @State private var editTarget: EditTarget?
    @State private var bookmarksOpen = false
    @State private var downloadCenterOpen = false
    @State private var isRailCollapsed = false
    @State private var sidebarStage: SidebarStage = .normal
    @State private var sidebarDragStart: CGFloat?
    @State private var liveSidebarWidth: CGFloat?
    @State private var spacesOpen = false
    @State private var workspacePreviewService = WorkspacePreviewService()
    @State private var spacesPhase: SpacesPhase = .closed
    @State private var morphImage: NSImage?
    @State private var morphProgress: Double = 0
    @State private var morphFrom: CGRect = .zero
    @State private var morphTo: CGRect = .zero
    @State private var morphTargetID: UUID?
    @State private var webCardFrame: CGRect = .zero
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var moving = false
    @ObserveInjection private var inject
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Initial root for the hosting view before the controller wires callbacks.
    static func placeholder(model: AppModel, settings: Settings, manager: WebViewManager, icons: IconStore, badges: BadgeStore, bookmarks: BookmarksModel) -> PanelRootView {
        PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons, badges: badges, bookmarks: bookmarks,
            onMoveBegan: {}, onMoveChanged: { _ in }, onMoveEnded: {}, onModalChange: { _ in }, onTabFocusChange: { _ in },
            onResizeBegan: {}, onResizeChanged: { _ in }, onResizeEnded: {}
        )
    }

    /// Sheets and the download center count as interactive overlays: while any
    /// is open the panel must not auto-hide on focus loss, or the popover's
    /// contents (e.g. the download list) vanish mid-interaction.
    private var isModalOpen: Bool { editTarget != nil || bookmarksOpen || downloadCenterOpen }
    private var anchor: PanelAnchor { settings.anchor }

    /// Shared-element transition stages between the browser layer and the
    /// Spaces overview (Astro view-transition style: snapshot flies web card ↔
    /// Space card while the two layers crossfade underneath).
    private enum SpacesPhase {
        case closed, morphIn, open, morphOut
    }

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
            // Keep the browser layer mounted while the Spaces layer enters above
            // it, just like Astro's old-document/new-document view transition.
            Color.clear
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .pointerCursor(moving ? .closedHand : .openHand)
            HStack(spacing: 0) {
                if anchor.railOnLeft {
                    if !isRailCollapsed {
                        rail.transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    webArea
                } else {
                    webArea
                    if !isRailCollapsed {
                        rail.transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            // Hidden while the morph layer carries the browser's snapshot into
            // the overview; it fades back in as the snapshot flies home so the
            // landing crossfades into the live page.
            .opacity(spacesPhase == .closed || spacesPhase == .morphOut ? 1 : 0)
            .allowsHitTesting(spacesPhase == .closed)
            .animation(reduceMotion ? nil : Motion.sidebarCollapse, value: spacesPhase == .closed || spacesPhase == .morphOut)
            if spacesOpen {
                SpacesOverview(
                    model: model,
                    settings: settings,
                    icons: icons,
                    previews: workspacePreviewService.previews,
                    hiddenPreviewID: spacesPhase == .morphIn || spacesPhase == .morphOut ? morphTargetID : nil,
                    onSelect: { id in
                        model.selectWorkspace(id)
                        if let selectedID = model.selectedID {
                            manager.activate(selectedID)
                            model.select(selectedID)
                        }
                        closeSpaces(to: id)
                    },
                    onNewWorkspace: {
                        model.addWorkspace()
                        if let selectedID = model.selectedID {
                            manager.activate(selectedID)
                            model.select(selectedID)
                        }
                        closeSpaces(to: nil)
                    },
                    onNewAgentWorkspace: {
                        model.addAgentWorkspace()
                        if let selectedID = model.selectedID {
                            manager.activate(selectedID)
                            model.select(selectedID)
                        }
                        closeSpaces(to: nil)
                    },
                    onClose: { closeSpaces(to: model.activeWorkspaceID) },
                    onCardFrameChange: handleCardFrameChange
                )
                .opacity(spacesPhase == .morphOut ? 0 : 1)
                .animation(reduceMotion ? nil : Motion.sidebarCollapse, value: spacesPhase)
                .zIndex(2)
            }
            if (spacesPhase == .morphIn || spacesPhase == .morphOut),
               morphTo.width > 1,
               morphTo.height > 1,
               let morphImage {
                Image(nsImage: morphImage)
                    .resizable()
                    .modifier(SpacesMorphModifier(
                        progress: morphProgress, from: morphFrom, to: morphTo,
                        fromCorner: spacesPhase == .morphIn ? Theme.webCardCorner : SpacesMorph.cardPreviewCorner,
                        toCorner: spacesPhase == .morphIn ? SpacesMorph.cardPreviewCorner : Theme.webCardCorner,
                        fromOpacity: spacesPhase == .morphIn ? 1 : 0.9,
                        toOpacity: spacesPhase == .morphIn ? 0.9 : 1
                    ))
                    .zIndex(3)
            }
        }
        .coordinateSpace(name: "panel")
        // The AppKit content host owns the single rounded clip for the window.
        // Keeping a second SwiftUI clip here can create an antialiased rim.
        // Native-style resize border on the panel's free edges + corner.
        .overlay {
            ResizeBorder(zones: anchor.resizeZones, hint: settings.strings.resizeHint,
                         onBegan: onResizeBegan, onChanged: onResizeChanged, onEnded: onResizeEnded)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : Motion.sidebarCollapse, value: spacesOpen)
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
        .onChange(of: downloadCenterOpen) { _, _ in onModalChange(isModalOpen) }
        .onExitCommand {
            if downloadCenterOpen { downloadCenterOpen = false }
        }
        // Moving the sidebar between edges must not tween the embedded browser
        // across the window. The real NSPanel already performs the dock snap;
        // swapping this layout atomically avoids a second expensive web redraw.
        .animation(reduceMotion ? nil : Motion.sidebarCollapse, value: isRailCollapsed)
        .enableInjection()
    }

    private var rail: some View {
        AppRail(
            model: model, settings: settings, icons: icons, badges: badges, width: sidebarWidth,
            onSelect: { id in model.select(id); manager.activate(id) },
            onNewTab: { groupID in
                let app = model.addBlankTab(toGroup: groupID)
                manager.activate(app.id)
                manager.state.focusOmniboxToken += 1
            },
            onEdit: { editTarget = EditTarget(app: $0) },
            onWorkspaceSwitched: {
                // Re-point the web area at the new workspace's active tab.
                if let id = model.selectedID {
                    manager.activate(id)
                    model.select(id)
                } else {
                    manager.state.currentID = nil
                }
            },
            onOpenSpaces: openSpaces,
            onReopenClosedTab: {
                if let app = model.reopenLastClosedTab() { manager.activate(app.id) }
            },
            onToggleMute: { manager.toggleMute($0) },
            onToggleSleep: { id in
                if manager.isAsleep(id) {
                    manager.wake(id)
                } else {
                    _ = manager.sleep(id)
                }
            },
            isAsleep: manager.isAsleep,
            onTabFocusChange: onTabFocusChange,
            onCollapse: { isRailCollapsed = true }
        )
    }

    private var sidebarWidth: CGFloat {
        liveSidebarWidth ?? sidebarStage.width
    }

    private func openSpaces() {
        guard !spacesOpen else { return }
        cardFrames.removeAll(keepingCapacity: true)
        workspacePreviewService.start(model: model, manager: manager)
        guard !reduceMotion,
              let image = workspacePreviewService.previews[model.activeWorkspaceID],
              webCardFrame.width > 1 else {
            morphImage = nil
            morphTargetID = nil
            spacesPhase = .open
            spacesOpen = true
            return
        }
        morphImage = image
        morphTargetID = model.activeWorkspaceID
        morphFrom = webCardFrame
        // Wait for the destination card's measured frame before rendering the
        // flight. Starting from the browser frame would briefly paint a large
        // page snapshot over the grid and cause the overflow seen on open.
        morphTo = .zero
        morphProgress = 0
        spacesPhase = .morphIn
        spacesOpen = true
        // The flight starts once the grid reports the target card's frame. If
        // that never arrives, drop the morph layer instead of covering the UI.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard spacesPhase == .morphIn, morphProgress == 0 else { return }
            morphImage = nil
            morphTargetID = nil
            spacesPhase = .open
        }
    }

    private func closeSpaces(to workspaceID: UUID?) {
        workspacePreviewService.stop()
        guard !reduceMotion,
              let id = workspaceID,
              let frame = cardFrames[id],
              let image = workspacePreviewService.previews[id],
              webCardFrame.width > 1 else {
            morphImage = nil
            morphTargetID = nil
            spacesPhase = .closed
            spacesOpen = false
            return
        }
        morphImage = image
        morphTargetID = id
        morphFrom = frame
        morphTo = webCardFrame
        morphProgress = 0
        spacesPhase = .morphOut
        withAnimation(Motion.spacesMorph) {
            morphProgress = 1
        } completion: {
            guard spacesPhase == .morphOut else { return }
            spacesPhase = .closed
            spacesOpen = false
            morphProgress = 0
            morphImage = nil
            morphTargetID = nil
        }
    }

    private func handleCardFrameChange(_ id: UUID, _ frame: CGRect) {
        cardFrames[id] = frame
        guard spacesPhase == .morphIn, id == morphTargetID, morphProgress == 0 else { return }
        morphTo = frame
        withAnimation(Motion.spacesMorph) {
            morphProgress = 1
        } completion: {
            if spacesPhase == .morphIn {
                spacesPhase = .open
            }
        }
    }

    private var sidebarResizeHandle: some View {
        SidebarResizeHandle(
            onBegan: {
                sidebarDragStart = sidebarWidth
            },
            onChanged: { translation in
                guard let start = sidebarDragStart else { return }
                let direction: CGFloat = anchor.railOnLeft ? 1 : -1
                liveSidebarWidth = SidebarStage.elasticWidth(start + translation * direction)
            },
            onEnded: {
                guard let width = liveSidebarWidth else {
                    sidebarDragStart = nil
                    return
                }
                let next = SidebarStage.nearest(to: width)
                withAnimation(reduceMotion ? nil : Motion.sidebarResize) {
                    sidebarStage = next
                    liveSidebarWidth = nil
                }
                sidebarDragStart = nil
            }
        )
        .transition(.opacity)
    }

    private var webArea: some View {
        ZStack(alignment: .top) {
            WebContainer(manager: manager, currentID: manager.state.currentID)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("panel"))
                } action: { frame in
                    webCardFrame = frame
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous))
                // No extra border or drop shadow: the web content should blend
                // into the panel background without a second rectangular rim.
                // Top inset clears the floating omnibox and leaves a small gap
                // between it and the web card.
                .padding(.top, 54)
                .padding([.bottom, .horizontal], 10)

            NavigationBar(
                state: manager.state, manager: manager, settings: settings,
                model: model, bookmarks: bookmarks, icons: icons,
                showsSidebarToggle: isRailCollapsed,
                sidebarOnLeft: anchor.railOnLeft,
                onMoveBegan: onMoveBegan, onMoveChanged: onMoveChanged, onMoveEnded: onMoveEnded,
                onBookmarks: { bookmarksOpen = true },
                onToggleSidebar: { isRailCollapsed = false },
                onDownloadsOpenChange: { downloadCenterOpen = $0 }
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if let error = manager.state.loadError {
                PageLoadErrorCard(
                    error: error,
                    canGoBack: manager.state.canGoBack,
                    settings: settings,
                    onRetry: manager.retryCurrentPage,
                    onBack: manager.goBack
                )
                .padding(.top, 54)
                .padding([.bottom, .horizontal], 10)
                .zIndex(1)
            } else if manager.state.rendererFailure != nil {
                RendererFailureCard(
                    canGoBack: manager.state.canGoBack,
                    settings: settings,
                    onRetry: manager.retryCurrentPage,
                    onBack: manager.goBack
                )
                .padding(.top, 54)
                .padding([.bottom, .horizontal], 10)
                .zIndex(1)
            }

            if manager.findBar.isVisible {
                FindBar(state: manager.findBar, manager: manager, settings: settings)
                    .padding(.top, 60)
                    .padding(.trailing, 18)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                    .zIndex(2)
            }
        }
        .animation(reduceMotion ? nil : Motion.dropdownOpen, value: manager.findBar.isVisible)
        // Chrome keeps one find session across tabs: re-run the query on the
        // newly activated page.
        .onChange(of: manager.state.currentID) { _, _ in
            if manager.findBar.isVisible { manager.findNext() }
        }
        .overlay(alignment: anchor.railOnLeft ? .leading : .trailing) {
            if !isRailCollapsed {
                sidebarResizeHandle
                    .offset(x: anchor.railOnLeft ? -4 : 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Native recovery surface for a failed main-frame load. The CEF error page
/// remains available to CDP underneath; this surface keeps the common retry and
/// history actions close to the page instead of forcing the user to use menus.
private struct PageLoadErrorCard: View {
    let error: WebLoadFailure
    let canGoBack: Bool
    let settings: Settings
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(settings.strings.pageLoadErrorTitle)
                .font(.title3.weight(.semibold))
            Text(settings.strings.pageLoadErrorMessage(error))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let url = error.url {
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button(settings.strings.retry, action: onRetry)
                    .buttonStyle(.borderedProminent)
                if canGoBack {
                    Button(settings.strings.back, action: onBack)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.strings.pageLoadErrorTitle)
    }
}

private struct RendererFailureCard: View {
    let canGoBack: Bool
    let settings: Settings
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(settings.strings.rendererFailureTitle)
                .font(.title3.weight(.semibold))
            Text(settings.strings.rendererFailureMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button(settings.strings.retry, action: onRetry)
                    .buttonStyle(.borderedProminent)
                if canGoBack {
                    Button(settings.strings.back, action: onBack)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.strings.rendererFailureTitle)
    }
}

/// Floating find-in-page bar (⌘F), pinned to the web card's top-trailing like
/// Chrome's. Return steps forward, ⇧Return backward; Esc is handled by the
/// panel's key monitor (find bar open beats hide-panel).
private struct FindBar: View {
    let state: FindBarState
    let manager: WebViewManager
    let settings: Settings

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(
                settings.strings.findInPage,
                text: Binding(get: { state.query }, set: { manager.updateFindQuery($0) })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .frame(width: 160)
            .focused($focused)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    manager.findPrevious()
                } else {
                    manager.findNext()
                }
                return .handled
            }
            findButton("chevron.up", label: settings.strings.findPrevious) { manager.findPrevious() }
            findButton("chevron.down", label: settings.strings.findNext) { manager.findNext() }
            findButton("xmark", label: settings.strings.close) { manager.closeFindBar() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule(style: .continuous))
        .onAppear { focused = true }
        .onChange(of: state.focusToken) { _, _ in focused = true }
    }

    private func findButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Opaque theme backdrop for the panel. The light appearance starts from pure
/// white; the dark appearance follows the system window background. The subtle
/// top wash preserves depth without allowing the desktop or page underneath to
/// bleed through the whole panel.
struct PanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var baseColor: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    var body: some View {
        ZStack {
            baseColor
            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        .primary.opacity(contrast == .increased ? 0.08 : 0.04),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Native-style resize border: near-invisible hit-zones along the panel's free
/// edges + corner. A real macOS window shows no visible grab — just the resize
/// cursor — so these stay transparent at rest. Docked edges have no zone (they
/// stay flush to the screen).
private struct ResizeBorder: View {
    let zones: [PanelResizeZone]
    let hint: String
    var onBegan: () -> Void
    var onChanged: ([PanelResizeEdge]) -> Void
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
/// panel's perimeter and carrying the matching native resize cursor. The
/// interactive layer is an AppKit view running the native mouse-tracking loop
/// (see `ResizeHandleView`), so the drag stays glued to the cursor instead of
/// lagging behind SwiftUI's `DragGesture` event delivery.
private struct ResizeZoneHandle: View {
    let zone: PanelResizeZone
    let hint: String
    var onBegan: () -> Void
    var onChanged: ([PanelResizeEdge]) -> Void
    var onEnded: () -> Void

    private static let edgeThickness: CGFloat = 8
    private static let cornerSize: CGFloat = 18

    var body: some View {
        // Size + hit-test the zone first, THEN position it. The fill axis (nil
        // dimension) stretches to the panel edge; the handle binds to this sized
        // band — never the full-panel positioning frame below, or the zone would
        // swallow hits across the whole panel.
        ResizeHandleView(cursor: cursor,
                         onBegan: onBegan,
                         onChanged: { onChanged(edges) },
                         onEnded: onEnded)
            .frame(width: fixedWidth, height: fixedHeight)
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

/// Bridges one resize zone to AppKit. The interactive surface is transparent —
/// the only hover affordance is the resize cursor, like a native window edge.
private struct ResizeHandleView: NSViewRepresentable {
    let cursor: NSCursor
    var onBegan: () -> Void
    var onChanged: () -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> ResizeHandleNSView { ResizeHandleNSView() }

    func updateNSView(_ view: ResizeHandleNSView, context: Context) {
        view.cursor = cursor
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

/// Divider between the rail and page. The hit zone stays narrow and reserves
/// almost no layout width; a slim vertical capsule marks the edge without
/// extending borders above or below it. AppKit owns the drag loop so width
/// changes follow the pointer directly, then SwiftUI springs to the nearest
/// stage on release.
private struct SidebarResizeHandle: View {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void
    @State private var hovering = false

    private static let hitWidth: CGFloat = 8
    var body: some View {
        SidebarResizeNSView(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
            .frame(width: Self.hitWidth)
            .overlay {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.72 : 0.52))
                    .frame(width: 3, height: 44)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Resize sidebar")
    }
}

/// AppKit-backed divider drag. SwiftUI's DragGesture batches updates behind
/// layout work; the event-tracking loop receives every mouse move and reports
/// the screen-space delta without adding an animation to the live width.
private struct SidebarResizeNSView: NSViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> SidebarResizeNSViewImpl {
        SidebarResizeNSViewImpl()
    }

    func updateNSView(_ view: SidebarResizeNSViewImpl, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

private final class SidebarResizeNSViewImpl: NSView {
    var onBegan: () -> Void = {}
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        let startX = screenX(for: event)
        onBegan()
        onChanged(0)

        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseUp {
                onChanged(screenX(for: next) - startX)
                break
            }
            onChanged(screenX(for: next) - startX)
        }
        onEnded()
    }

    private func screenX(for event: NSEvent) -> CGFloat {
        guard let window else { return NSEvent.mouseLocation.x }
        return window.convertPoint(toScreen: event.locationInWindow).x
    }
}

/// Transparent edge/corner grip that drives the resize from AppKit's own
/// mouse-tracking loop. Draining `.leftMouseDragged` events ourselves keeps the
/// frame glued to the cursor 1:1 — SwiftUI's `DragGesture` delivers updates a
/// frame or two late, which reads as drag "lag". `acceptsFirstMouse` lets a grab
/// resize immediately, without first clicking to focus the panel.
final class ResizeHandleNSView: NSView {
    var cursor: NSCursor = .arrow
    var onBegan: () -> Void = {}
    var onChanged: () -> Void = {}
    var onEnded: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseDown(with event: NSEvent) {
        cursor.set()
        onBegan()
        onChanged()
        // Native resize loop: process only drag/up events until the mouse lifts,
        // updating on every event so the panel tracks the cursor without latency.
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                         until: .distantFuture,
                                         inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            onChanged()
        }
        onEnded()
    }
}
