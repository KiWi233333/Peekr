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
    let badges: BadgeStore
    let bookmarks: BookmarksModel

    var onVisibilityChange: ((Bool) -> Void)?

    private let panel: SlidePanel
    private var hosting: NSHostingView<PanelRootView>!

    private(set) var isVisible = false
    private var autoHideSuspended = false
    private var tabRailFocused = false
    private var activeScreen: NSScreen?

    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
    private var keyMonitor: Any?
    private var resignKeyObserver: Any?
    private var dragStartOrigin: NSPoint = .zero
    private var dragStartMouse: NSPoint = .zero
    private var resizeStartFrame: NSRect = .zero
    /// The size being dragged out right now. While set it wins over the stored
    /// per-app size, so the panel tracks the cursor without writing to the model
    /// on every frame; it's committed once on `resizeEnded`.
    private var liveResize: NSSize?

    init(model: AppModel, settings: Settings, manager: WebViewManager, icons: IconStore, badges: BadgeStore, bookmarks: BookmarksModel) {
        self.model = model
        self.settings = settings
        self.manager = manager
        self.icons = icons
        self.badges = badges
        self.bookmarks = bookmarks

        panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640))

        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.panelCorner
        container.layer?.masksToBounds = true

        hosting = NSHostingView(rootView: PanelRootView.placeholder(model: model, settings: settings, manager: manager, icons: icons, badges: badges, bookmarks: bookmarks))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        // The panel surface is an opaque, rounded content host. Liquid Glass is
        // applied to functional chrome inside the panel, not the whole browser
        // content layer, so the window edge has no extra glass rim.
        let panelSurface = makePanelBackdrop(
            contentView: container,
            cornerRadius: Theme.panelCorner
        )
        panelSurface.frame = NSRect(origin: .zero, size: panel.frame.size)
        panelSurface.autoresizingMask = [.width, .height]
        panel.contentView = panelSurface

        // Real callbacks once self is fully initialised.
        hosting.rootView = PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons, badges: badges, bookmarks: bookmarks,
            onMoveBegan: { [weak self] in self?.moveBegan() },
            onMoveChanged: { [weak self] t in self?.moveChanged(t) },
            onMoveEnded: { [weak self] in self?.moveEnded() },
            onModalChange: { [weak self] open in self?.autoHideSuspended = open },
            onTabFocusChange: { [weak self] focused in self?.tabRailFocused = focused },
            onResizeBegan: { [weak self] in self?.resizeBegan() },
            onResizeChanged: { [weak self] edges in self?.resizeChanged(edges) },
            onResizeEnded: { [weak self] in self?.resizeEnded() }
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
        animate(to: layout.onscreen, duration: Motion.Duration.panelOpen)
        installMonitors()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        tabRailFocused = false
        onVisibilityChange?(false)
        removeMonitors()

        let layout = currentLayout(on: activeScreen ?? resolveScreen())
        Motion.appKit(Motion.Duration.panelClose, animations: { [panel] in
            panel.animator().setFrame(layout.offscreen, display: true)
        }, reducedMotion: { [panel] in
            panel.setFrame(layout.offscreen, display: true)
        }, completion: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Re-apply size/anchor while visible (after preference changes).
    func applyLayout() {
        guard isVisible, let screen = activeScreen else { return }
        animate(to: currentLayout(on: screen).onscreen, duration: Motion.Duration.panelLayout)
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

        animate(to: currentLayout(on: screen).onscreen, duration: Motion.Duration.panelSnap)
        autoHideSuspended = false
    }

    // MARK: - Resize

    private func resizeBegan() {
        autoHideSuspended = true
        resizeStartFrame = panel.frame
        dragStartMouse = NSEvent.mouseLocation
        liveResize = panel.frame.size
    }

    /// One edge for an edge handle, two (a width + a height edge) for a corner.
    private func resizeChanged(_ edges: [PanelResizeEdge]) {
        guard let screen = activeScreen else { return }
        // Absolute screen-coordinate deltas (y is up), same anti-jitter reason
        // as moveChanged.
        let dx = NSEvent.mouseLocation.x - dragStartMouse.x
        let dy = NSEvent.mouseLocation.y - dragStartMouse.y
        let frame = PanelGeometry.resizedFrame(
            from: resizeStartFrame,
            dragging: edges,
            delta: NSSize(width: dx, height: dy),
            within: screen.visibleFrame)
        liveResize = frame.size
        // Suppress implicit layer animations during the live drag. The rounded
        // content host can animate its bounds by default, which makes the panel
        // lag behind the cursor ("resistance") on every frame.
        // Disabling actions makes the resize track the cursor 1:1; the snap
        // animation on `animate(...)` still applies elsewhere.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        CATransaction.commit()
    }

    private func resizeEnded() {
        if let size = liveResize {
            // One global panel size, shared across every tab.
            settings.panelWidth = size.width
            settings.panelHeight = size.height
            settings.persist()
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
            // Panel shortcuts only apply to the panel itself: a key Preferences
            // window, sheet or DevTools window must not trigger panel actions.
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                if self.manager.findBar.isVisible {
                    self.manager.closeFindBar()
                    return nil
                }
                // A focused text field (omnibox, find bar, tab rename) owns Esc —
                // let its own handling run instead of hiding the panel.
                if self.panel.firstResponder is NSTextView { return event }
                self.hide()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == UInt16(kVK_Tab), flags.contains(.control) {
                self.handleControlTab(reverse: flags.contains(.shift))
                return nil
            }
            if event.modifierFlags.contains(.command), self.handleCommand(event) { return nil }
            return event
        }
        // Focus-loss auto-hide: the panel resigns key when another app/window is
        // clicked. (Mouse-leave mode relies on the move monitors above instead.)
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocusLoss() }
        }
    }

    private func removeMonitors() {
        for monitor in [moveMonitorGlobal, moveMonitorLocal, keyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        moveMonitorGlobal = nil; moveMonitorLocal = nil; keyMonitor = nil
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
    }

    /// Shared auto-hide guards: visible, enabled, not pinned, no drag/sheet/modal
    /// in progress.
    private var canAutoHide: Bool {
        isVisible && settings.autoHide && !model.isPinned && !autoHideSuspended
            && NSApp.modalWindow == nil && panel.attachedSheet == nil
    }

    private func checkLeave() {
        guard canAutoHide, settings.autoHideMode == .mouseLeave else { return }
        let loc = NSEvent.mouseLocation
        if !panel.frame.insetBy(dx: -12, dy: -12).contains(loc) {
            hide()
        }
    }

    private func checkFocusLoss() {
        guard canAutoHide, settings.autoHideMode == .focusLoss else { return }
        hide()
    }

    /// Browser-style shortcuts while the panel is key. Returns true if consumed.
    private func handleCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Arrow keys carry no printable characters, so branch on keyCode.
        if event.keyCode == UInt16(kVK_LeftArrow) || event.keyCode == UInt16(kVK_RightArrow) {
            let back = event.keyCode == UInt16(kVK_LeftArrow)
            // ⌘⌥←/→ walk the tab strip (Chrome); plain ⌘←/→ navigate history —
            // except while a text field owns them for caret movement.
            if flags.contains(.option) {
                handleControlTab(reverse: back)
            } else {
                guard !(panel.firstResponder is NSTextView) else { return false }
                back ? manager.goBack() : manager.goForward()
            }
            return true
        }
        guard let chars = event.charactersIgnoringModifiers else { return false }
        switch chars {
        case "l": manager.state.focusOmniboxToken += 1
        case "r":
            if flags.contains(.shift) {
                manager.reloadIgnoringCache()
            } else {
                manager.reloadOrStop()
            }
        case "[": manager.goBack()
        case "]": manager.goForward()
        case "d":
            let url = manager.state.urlString
            guard !url.isEmpty else { return false }
            let title = manager.state.title
            bookmarks.add(title: title.isEmpty ? url : title, urlString: url)
        case "f": manager.openFindBar()
        case "=", "+": manager.zoomIn()
        case "-": manager.zoomOut()
        case "0": manager.zoomReset()
        case "t":
            if event.modifierFlags.contains(.shift) {
                if let app = model.reopenLastClosedTab() { manager.activate(app.id) }
            } else {
                let app = model.addBlankTab()
                manager.activate(app.id)
                manager.state.focusOmniboxToken += 1
            }
        case "w":
            guard tabRailFocused else { hide(); return true }
            tabRailFocused = false
            guard let id = model.selectedID else { hide(); return true }
            model.removeApp(id)
            if let nextID = model.selectedID {
                manager.activate(nextID)
            } else {
                manager.state.currentID = nil
            }
        default:
            guard let n = Int(chars), let id = model.selectShortcutTab(n) else { return false }
            manager.activate(id)
        }
        return true
    }

    private func handleControlTab(reverse: Bool) {
        guard let id = model.selectAdjacentTab(reverse: reverse) else { return }
        manager.activate(id)
    }

    // MARK: - Helpers

    private func currentLayout(on screen: NSScreen) -> PanelLayout {
        PanelGeometry.layout(anchor: settings.anchor, screen: screen, size: panelSize(on: screen))
    }

    private func panelSize(on screen: NSScreen) -> NSSize {
        let visible = screen.visibleFrame.size
        // A live resize already produced a clamped size; reuse the same clamp.
        if let liveResize {
            return PanelGeometry.resolveSize(global: liveResize, visible: visible)
        }
        let global = NSSize(width: settings.panelWidth, height: settings.panelHeight)
        return PanelGeometry.resolveSize(global: global, visible: visible)
    }

    private func animate(to frame: NSRect, duration: TimeInterval) {
        Motion.appKit(duration, animations: { [panel] in
            panel.animator().setFrame(frame, display: true)
        }, reducedMotion: { [panel] in
            panel.setFrame(frame, display: true)
        })
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
