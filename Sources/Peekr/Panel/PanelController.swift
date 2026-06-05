import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the slide panel: anchoring, slide animation, edge auto-hide, pin,
/// drag-to-snap (8 positions, multi-display) and edge resizing.
///
/// The panel keeps a user-chosen size. Snapping only re-docks it and changes
/// the slide direction — it never resizes the window.
@MainActor
final class PanelController {
    let model: AppModel
    let settings: Settings
    let manager: WebViewManager
    let icons: IconStore
    let bookmarks: BookmarksModel

    var onVisibilityChange: ((Bool) -> Void)?

    private let panel: SlidePanel
    private let backdrop = makePanelBackdrop(cornerRadius: Theme.panelCorner)
    private var hosting: NSHostingView<PanelRootView>!

    private(set) var isVisible = false
    private var autoHideSuspended = false
    private var activeScreen: NSScreen?

    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
    private var keyMonitor: Any?
    private var dragStartOrigin: NSPoint = .zero
    private var dragStartMouse: NSPoint = .zero
    private var resizeStartSize: NSSize = .zero
    /// The size being dragged out right now. While set it wins over the stored
    /// per-app size, so the panel tracks the cursor without writing to the model
    /// on every frame; it's committed once on `resizeEnded`.
    private var liveResize: NSSize?

    init(model: AppModel, settings: Settings, manager: WebViewManager, icons: IconStore, bookmarks: BookmarksModel) {
        self.model = model
        self.settings = settings
        self.manager = manager
        self.icons = icons
        self.bookmarks = bookmarks

        panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640))

        let container = NSView(frame: panel.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.panelCorner
        container.layer?.masksToBounds = true

        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)

        hosting = NSHostingView(rootView: PanelRootView.placeholder(model: model, settings: settings, manager: manager, icons: icons, bookmarks: bookmarks))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        // Real callbacks once self is fully initialised.
        hosting.rootView = PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons, bookmarks: bookmarks,
            onMoveBegan: { [weak self] in self?.moveBegan() },
            onMoveChanged: { [weak self] t in self?.moveChanged(t) },
            onMoveEnded: { [weak self] in self?.moveEnded() },
            onModalChange: { [weak self] open in self?.autoHideSuspended = open },
            onResizeBegan: { [weak self] in self?.resizeBegan() },
            onResizeChanged: { [weak self] edges, t in self?.resizeChanged(edges, t) },
            onResizeEnded: { [weak self] in self?.resizeEnded() },
            onSizeReapply: { [weak self] in self?.applyLayout() }
        )
    }

    // MARK: - Show / hide

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        onVisibilityChange?(true)

        let screen = resolveScreen()
        activeScreen = screen
        persistScreen(screen)

        if model.selectedID == nil { model.selectedID = model.apps.first?.id }
        if let id = model.selectedID { manager.activate(id) }

        let layout = currentLayout(on: screen)
        panel.setFrame(layout.offscreen, display: false)
        panel.makeKeyAndOrderFront(nil)
        animate(to: layout.onscreen, duration: 0.24, curve: .easeOut)
        installMonitors()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        onVisibilityChange?(false)
        removeMonitors()

        let layout = currentLayout(on: activeScreen ?? resolveScreen())
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(layout.offscreen, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Re-apply size/anchor while visible (after preference changes).
    func applyLayout() {
        guard isVisible, let screen = activeScreen else { return }
        animate(to: currentLayout(on: screen).onscreen, duration: 0.25, curve: .easeInEaseOut)
    }

    // MARK: - Drag to snap (position + slide direction only — never size)

    private func moveBegan() {
        autoHideSuspended = true
        dragStartOrigin = panel.frame.origin
        dragStartMouse = NSEvent.mouseLocation
    }

    /// Move by the delta of the *absolute* screen mouse position, not the
    /// gesture's translation. The gesture lives inside the window, so its
    /// reference frame moves as the window moves — using it creates a feedback
    /// loop that jitters (and worsens across displays). Screen coordinates are
    /// stable, so the window tracks the cursor 1:1 with no oscillation.
    private func moveChanged(_ translation: CGSize) {
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(
            x: dragStartOrigin.x + (mouse.x - dragStartMouse.x),
            y: dragStartOrigin.y + (mouse.y - dragStartMouse.y)
        ))
    }

    private func moveEnded() {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.screens.first { $0.frame.contains(center) }
            ?? activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
        activeScreen = screen

        settings.anchor = PanelGeometry.nearestAnchor(to: center, on: screen)
        persistScreen(screen)
        settings.persist()

        animate(to: currentLayout(on: screen).onscreen, duration: 0.3, curve: .easeOut)
        autoHideSuspended = false
    }

    // MARK: - Resize

    private func resizeBegan() {
        autoHideSuspended = true
        resizeStartSize = panel.frame.size
        dragStartMouse = NSEvent.mouseLocation
        liveResize = panel.frame.size
    }

    /// One edge for an edge handle, two (a width + a height edge) for a corner.
    private func resizeChanged(_ edges: [PanelResizeEdge], _ translation: CGSize) {
        guard let screen = activeScreen else { return }
        let vf = screen.visibleFrame
        // Absolute screen-coordinate deltas (y is up), same anti-jitter reason
        // as moveChanged.
        let dx = NSEvent.mouseLocation.x - dragStartMouse.x
        let dy = NSEvent.mouseLocation.y - dragStartMouse.y
        var w = resizeStartSize.width
        var h = resizeStartSize.height
        for edge in edges {
            switch edge {
            case .trailing: w = resizeStartSize.width + dx
            case .leading:  w = resizeStartSize.width - dx
            case .top:      h = resizeStartSize.height + dy
            case .bottom:   h = resizeStartSize.height - dy
            }
        }
        liveResize = NSSize(
            width: min(max(PanelGeometry.minSize.width, w), vf.width),
            height: min(max(PanelGeometry.minSize.height, h), vf.height))
        // Suppress implicit layer animations during the live drag. The glass
        // backdrop (NSGlassEffectView) animates its bounds by default, which
        // makes the panel lag behind the cursor ("resistance") on every frame.
        // Disabling actions makes the resize track the cursor 1:1; the snap
        // animation on `animate(...)` still applies elsewhere.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(currentLayout(on: screen).onscreen, display: true)
        CATransaction.commit()
    }

    private func resizeEnded() {
        if let size = liveResize {
            if let id = model.selectedID {
                // Remember this size for the active app only.
                model.setPanelSize(id, width: size.width, height: size.height)
            } else {
                // No active tab (empty workspace): seed the global default that
                // not-yet-resized apps inherit, so resizing still does something.
                settings.panelWidth = size.width
                settings.panelHeight = size.height
                settings.persist()
            }
        }
        liveResize = nil
        autoHideSuspended = false
    }

    // MARK: - Auto-hide monitors

    private func installMonitors() {
        moveMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.checkLeave()
        }
        moveMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.checkLeave()
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.hide(); return nil }
            if event.modifierFlags.contains(.command), self.handleCommand(event) { return nil }
            return event
        }
    }

    private func removeMonitors() {
        for monitor in [moveMonitorGlobal, moveMonitorLocal, keyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        moveMonitorGlobal = nil; moveMonitorLocal = nil; keyMonitor = nil
    }

    private func checkLeave() {
        guard isVisible, settings.autoHide, !model.isPinned, !autoHideSuspended,
              NSApp.modalWindow == nil
        else { return }
        let loc = NSEvent.mouseLocation
        if !panel.frame.insetBy(dx: -12, dy: -12).contains(loc) {
            hide()
        }
    }

    /// Browser-style shortcuts while the panel is key. Returns true if consumed.
    private func handleCommand(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers else { return false }
        switch chars {
        case "l": manager.state.focusOmniboxToken += 1
        case "r": manager.reloadOrStop()
        case "[": manager.goBack()
        case "]": manager.goForward()
        case "w": hide()
        default:
            guard let n = Int(chars), (1...9).contains(n), n - 1 < model.apps.count else { return false }
            let id = model.apps[n - 1].id
            model.select(id)
            manager.activate(id)
            applyLayout()   // restore this app's remembered size
        }
        return true
    }

    // MARK: - Helpers

    private func currentLayout(on screen: NSScreen) -> PanelLayout {
        PanelGeometry.layout(anchor: settings.anchor, screen: screen, size: panelSize(on: screen))
    }

    private var activeApp: WebApp? {
        model.selectedID.flatMap { id in model.apps.first { $0.id == id } }
    }

    private func panelSize(on screen: NSScreen) -> NSSize {
        let visible = screen.visibleFrame.size
        // A live resize already produced a clamped size; reuse the same clamp.
        if let liveResize {
            return PanelGeometry.resolveSize(app: liveResize, global: .zero, visible: visible)
        }
        let app = activeApp.map { NSSize(width: $0.panelWidth, height: $0.panelHeight) } ?? .zero
        let global = NSSize(width: settings.panelWidth, height: settings.panelHeight)
        return PanelGeometry.resolveSize(app: app, global: global, visible: visible)
    }

    private func animate(to frame: NSRect, duration: TimeInterval, curve: CAMediaTimingFunctionName) {
        // Honor the system reduced-motion preference (native apps do).
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: curve)
            // Let the hosted WKWebView keep painting during the slide instead of
            // freezing (legacy Cocoa resize suspends subview drawing). Survival A.4.
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func resolveScreen() -> NSScreen {
        if settings.followCursor {
            let loc = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) {
                return screen
            }
        }
        if let number = settings.lastScreenNumber,
           let screen = NSScreen.screens.first(where: { $0.screenNumber == number }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func persistScreen(_ screen: NSScreen) {
        if let number = screen.screenNumber, number != settings.lastScreenNumber {
            settings.lastScreenNumber = number
            settings.persist()
        }
    }
}
