import AppKit

/// Owns the slide panel and drives the show / hide / slide animations,
/// edge auto-hide and pin behaviour.
@MainActor
final class PanelController {
    let model: AppModel
    let webManager: WebViewManager

    private let panel: SlidePanel
    private let content: PanelContentView

    var panelWidth: CGFloat = 440
    private(set) var isVisible = false

    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        webManager = WebViewManager(model: model)
        panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        content = PanelContentView(model: model, webManager: webManager)
        panel.contentView = content
    }

    // MARK: - Public

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true

        let screen = targetScreen
        let vf = screen.visibleFrame
        let onscreen = NSRect(x: vf.maxX - panelWidth, y: vf.minY, width: panelWidth, height: vf.height)
        let offscreen = NSRect(x: screen.frame.maxX, y: vf.minY, width: panelWidth, height: vf.height)

        if model.selectedID == nil { model.selectedID = model.apps.first?.id }
        if let id = model.selectedID { webManager.show(id) }

        panel.setFrame(offscreen, display: false)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(onscreen, display: true)
        }

        installMonitors()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()

        let screen = targetScreen
        let f = panel.frame
        let offscreen = NSRect(x: screen.frame.maxX, y: f.minY, width: f.width, height: f.height)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offscreen, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Auto-hide

    private func installMonitors() {
        moveMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.checkLeave()
        }
        moveMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.checkLeave()
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        for monitor in [moveMonitorGlobal, moveMonitorLocal, keyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        moveMonitorGlobal = nil
        moveMonitorLocal = nil
        keyMonitor = nil
    }

    private func checkLeave() {
        guard isVisible, !model.isPinned, NSApp.modalWindow == nil else { return }
        let loc = NSEvent.mouseLocation
        // Hide once the cursor leaves the panel to the left (with a small margin).
        if !panel.frame.insetBy(dx: -8, dy: 0).contains(loc) {
            hide()
        }
    }

    private var targetScreen: NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
