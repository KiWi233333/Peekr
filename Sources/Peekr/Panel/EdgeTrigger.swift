import AppKit

/// Watches the cursor and fires when it reaches the right edge of any screen.
/// Uses a global mouse-moved monitor (no Accessibility permission required for
/// reading mouse location) rather than an intercepting edge window.
@MainActor
final class EdgeTrigger {
    var onTrigger: (() -> Void)?
    var edgeThreshold: CGFloat = 2
    var enabled = true

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func check() {
        guard enabled else { return }
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) else { return }
        if loc.x >= screen.frame.maxX - edgeThreshold {
            onTrigger?()
        }
    }
}
