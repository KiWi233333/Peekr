import AppKit
import SwiftUI

/// Owns the slide panel: anchoring, slide animation, edge auto-hide, pin,
/// and drag-to-snap across 8 positions and multiple displays.
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

    init(model: AppModel, settings: Settings, manager: WebViewManager, icons: IconStore) {
        self.model = model
        self.settings = settings
        self.manager = manager
        self.icons = icons

        panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: settings.panelWidth, height: 640))

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

        let root = PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons,
            onMoveBegan: { },
            onMoveChanged: { _ in },
            onMoveEnded: { },
            onModalChange: { _ in }
        )
        hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        panel.contentView = container

        // Wire callbacks now that self is fully initialised.
        hosting.rootView = PanelRootView(
            model: model, settings: settings, manager: manager, icons: icons,
            onMoveBegan: { [weak self] in self?.moveBegan() },
            onMoveChanged: { [weak self] t in self?.moveChanged(t) },
            onMoveEnded: { [weak self] in self?.moveEnded() },
            onModalChange: { [weak self] open in self?.autoHideSuspended = open }
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

        let layout = PanelGeometry.layout(anchor: settings.anchor, screen: screen, width: settings.panelWidth)
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

        let screen = activeScreen ?? resolveScreen()
        let layout = PanelGeometry.layout(anchor: settings.anchor, screen: screen, width: settings.panelWidth)
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

    /// Re-apply width/anchor while visible (called after preference changes).
    func applyLayout() {
        guard isVisible, let screen = activeScreen else { return }
        let layout = PanelGeometry.layout(anchor: settings.anchor, screen: screen, width: settings.panelWidth)
        animate(to: layout.onscreen, duration: 0.25, curve: .easeInEaseOut)
    }

    // MARK: - Drag to snap

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

        let anchor = PanelGeometry.nearestAnchor(to: center, on: screen)
        settings.anchor = anchor
        persistScreen(screen)
        settings.persist()

        let layout = PanelGeometry.layout(anchor: anchor, screen: screen, width: settings.panelWidth)
        animate(to: layout.onscreen, duration: 0.3, curve: .easeOut)
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
            if event.keyCode == 53 { self?.hide(); return nil } // Escape
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

    // MARK: - Helpers

    private func animate(to frame: NSRect, duration: TimeInterval, curve: CAMediaTimingFunctionName) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: curve)
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
