import AppKit

/// Menu-bar item with toggle / pin / quit.
@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let model: AppModel
    private let onToggle: () -> Void
    private let onTogglePin: () -> Void
    private var pinItem: NSMenuItem!

    init(
        model: AppModel,
        onToggle: @escaping () -> Void,
        onTogglePin: @escaping () -> Void
    ) {
        self.model = model
        self.onToggle = onToggle
        self.onTogglePin = onTogglePin
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "sidebar.trailing",
                accessibilityDescription: "Peekr"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Toggle Peekr", action: #selector(toggleAction), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        pinItem = NSMenuItem(title: "Pin Open", action: #selector(pinAction), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Peekr", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func toggleAction() { onToggle() }

    @objc private func pinAction() {
        onTogglePin()
        pinItem.state = model.isPinned ? .on : .off
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}
