import AppKit

/// Menu-bar item: toggle / pin / preferences / quit. Titles localize live.
@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let model: AppModel
    private let settings: Settings
    private let onToggle: () -> Void
    private let onTogglePin: () -> Void
    private let onPreferences: () -> Void
    private let onQuit: () -> Void

    private var toggleItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    private var prefsItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    init(
        model: AppModel,
        settings: Settings,
        onToggle: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onPreferences: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.onToggle = onToggle
        self.onTogglePin = onTogglePin
        self.onPreferences = onPreferences
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        item.isVisible = true
        if let button = item.button {
            button.image = BrandGlyph.image(size: 18)
        }

        let menu = NSMenu()
        menu.delegate = self
        toggleItem = addItem(to: menu, action: #selector(toggleAction), key: "")
        pinItem = addItem(to: menu, action: #selector(pinAction), key: "")
        menu.addItem(.separator())
        prefsItem = addItem(to: menu, action: #selector(prefsAction), key: ",")
        menu.addItem(.separator())
        quitItem = addItem(to: menu, action: #selector(quitAction), key: "q")
        item.menu = menu
    }

    private func addItem(to menu: NSMenu, action: Selector, key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "", action: action, keyEquivalent: key)
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    @objc private func toggleAction() { onToggle() }
    @objc private func pinAction() { onTogglePin() }
    @objc private func prefsAction() { onPreferences() }
    @objc private func quitAction() { onQuit() }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let loc = settings.strings
        toggleItem.title = loc.toggle
        pinItem.title = loc.pinOpen
        pinItem.state = model.isPinned ? .on : .off
        prefsItem.title = loc.preferences
        quitItem.title = loc.quit
    }
}
