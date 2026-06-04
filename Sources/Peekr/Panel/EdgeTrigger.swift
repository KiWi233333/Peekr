import AppKit

/// Watches the cursor and fires after it dwells in the active anchor's trigger
/// zone for `settings.hoverDelay`. Disarmed while the panel is open.
@MainActor
final class EdgeTrigger {
    var onTrigger: (() -> Void)?

    private let settings: Settings
    private var monitor: Any?
    private var pending: DispatchWorkItem?
    private var armed = true

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.check()
        }
    }

    func setArmed(_ value: Bool) {
        armed = value
        if !value { cancelPending() }
    }

    // MARK: - Private

    private func check() {
        guard armed else { return }
        guard let (screen, loc) = currentScreen() else { cancelPending(); return }
        let region = PanelGeometry.triggerRegion(
            anchor: settings.anchor, screen: screen, thickness: CGFloat(settings.edgeThreshold)
        )
        if region.contains(loc) {
            if pending == nil { schedule() }
        } else {
            cancelPending()
        }
    }

    private func schedule() {
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settings.hoverDelay), execute: work)
    }

    private func fire() {
        pending = nil
        guard armed, let (screen, loc) = currentScreen() else { return }
        let region = PanelGeometry.triggerRegion(
            anchor: settings.anchor, screen: screen, thickness: CGFloat(settings.edgeThreshold)
        )
        if region.contains(loc) { onTrigger?() }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func currentScreen() -> (NSScreen, NSPoint)? {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) else { return nil }
        return (screen, loc)
    }
}
