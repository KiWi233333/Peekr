import AppKit
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

    var onVisibilityChange: ((Bool) -> Void)?

    private let panel: SlidePanel
    private let backdrop = NSVisualEffectView()
    private var hosting: NSHostingView<PanelRootView>!

    private(set) var isVisible = false
    private var autoHideSuspended = false
    private var activeScreen: NSScreen?

    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
    private var keyMonitor: Any?
    private var dragStartOrigin: NSPoint = .zero
    private var resizeStartSize: NSSize = .zero

    init(model: AppModel, settings: Settings, manager: WebViewManager, icons: IconStore) {
        self.model = model
        self.settings = settings
        self.manager = manager
        self.icons = icons

        panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640))

        let container = NSView(frame: panel.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.panelCorner
        container.layer?.masksToBounds = true

        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)

        hosting = NSHostingView(rootView: PanelRootView.placeholder(model: model, settings: settings, manager: manager, icons: icons))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        // Real callbacks once self is fully initialised.
        hosting.rootView = PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons,
            onMoveBegan: { [weak self] in self?.moveBegan() },
            onMoveChanged: { [weak self] t in self?.moveChanged(t) },
            onMoveEnded: { [weak self] in self?.moveEnded() },
            onModalChange: { [weak self] open in self?.autoHideSuspended = open },
            onResizeBegan: { [weak self] in self?.resizeBegan() },
            onResizeChanged: { [weak self] edge, t in self?.resizeChanged(edge, t) },
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
    }

    private func moveChanged(_ translation: CGSize) {
        panel.setFrameOrigin(NSPoint(
            x: dragStartOrigin.x + translation.width,
            y: dragStartOrigin.y - translation.height
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
    }

    private func resizeChanged(_ edge: PanelResizeEdge, _ translation: CGSize) {
        guard let screen = activeScreen else { return }
        let vf = screen.visibleFrame
        var w = resizeStartSize.width
        var h = resizeStartSize.height
        switch edge {
        case .trailing: w = resizeStartSize.width + translation.width
        case .leading:  w = resizeStartSize.width - translation.width
        case .bottom:   h = resizeStartSize.height + translation.height
        case .top:      h = resizeStartSize.height - translation.height
        }
        settings.panelWidth = min(max(280, w), Double(vf.width))
        settings.panelHeight = min(max(240, h), Double(vf.height))
        panel.setFrame(currentLayout(on: screen).onscreen, display: true)
    }

    private func resizeEnded() {
        settings.persist()
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
            if event.keyCode == 53 { self.hide(); return nil } // Escape
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
        }
        return true
    }

    // MARK: - Helpers

    private func currentLayout(on screen: NSScreen) -> PanelLayout {
        PanelGeometry.layout(anchor: settings.anchor, screen: screen, size: panelSize(on: screen))
    }

    private func panelSize(on screen: NSScreen) -> NSSize {
        let fallback = PanelGeometry.defaultSize(for: screen)
        let w = settings.panelWidth > 0 ? CGFloat(settings.panelWidth) : fallback.width
        let h = settings.panelHeight > 0 ? CGFloat(settings.panelHeight) : fallback.height
        let vf = screen.visibleFrame
        return NSSize(width: min(w, vf.width), height: min(h, vf.height))
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
