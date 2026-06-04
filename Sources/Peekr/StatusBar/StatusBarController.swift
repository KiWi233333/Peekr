import AppKit

/// Menu-bar item: toggle / pin / preferences / quit.
@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let model: AppModel
    private let onToggle: () -> Void
    private let onTogglePin: () -> Void
    private let onPreferences: () -> Void
    private var pinItem: NSMenuItem!

    init(
        model: AppModel,
        onToggle: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onPreferences: @escaping () -> Void
    ) {
        self.model = model
        self.onToggle = onToggle
        self.onTogglePin = onTogglePin
        self.onPreferences = onPreferences
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Peekr")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        addItem(to: menu, title: "Toggle Peekr", action: #selector(toggleAction), key: "")
        pinItem = addItem(to: menu, title: "Pin Open", action: #selector(pinAction), key: "")
        menu.addItem(.separator())
        addItem(to: menu, title: "Preferences…", action: #selector(prefsAction), key: ",")
        menu.addItem(.separator())
        addItem(to: menu, title: "Quit Peekr", action: #selector(quitAction), key: "q")
        item.menu = menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    @objc private func toggleAction() { onToggle() }
    @objc private func pinAction() { onTogglePin() }
    @objc private func prefsAction() { onPreferences() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        pinItem.state = model.isPinned ? .on : .off
    }
}
