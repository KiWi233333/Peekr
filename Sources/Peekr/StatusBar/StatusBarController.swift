import AppKit
import Carbon.HIToolbox

/// Native menu-bar menu for immediate, reversible actions. Titles and checked
/// state localize and refresh whenever the menu opens.
@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let model: AppModel
    private let settings: Settings
    private let isPanelVisible: () -> Bool
    private let onToggle: () -> Void
    private let onTogglePin: () -> Void
    private let onImportCookies: () -> Void
    private let onImportBookmarks: () -> Void
    private let onPreferences: () -> Void
    private let onQuit: () -> Void

    private var toggleItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    private var autoHideItem: NSMenuItem!
    private var autoHideItems: [AutoHidePolicy: NSMenuItem] = [:]
    private var importChromeItem: NSMenuItem!
    private var importCookiesItem: NSMenuItem!
    private var importBookmarksItem: NSMenuItem!
    private var prefsItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    init(
        model: AppModel,
        settings: Settings,
        isPanelVisible: @escaping () -> Bool,
        onToggle: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onImportCookies: @escaping () -> Void,
        onImportBookmarks: @escaping () -> Void,
        onPreferences: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.isPanelVisible = isPanelVisible
        self.onToggle = onToggle
        self.onTogglePin = onTogglePin
        self.onImportCookies = onImportCookies
        self.onImportBookmarks = onImportBookmarks
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
        autoHideItem = NSMenuItem()
        let autoHideMenu = NSMenu()
        for policy in AutoHidePolicy.allCases {
            let policyItem = addItem(
                to: autoHideMenu,
                action: #selector(autoHideAction(_:)),
                key: ""
            )
            policyItem.representedObject = policy.rawValue
            autoHideItems[policy] = policyItem
        }
        autoHideItem.submenu = autoHideMenu
        menu.addItem(autoHideItem)

        menu.addItem(.separator())

        importChromeItem = NSMenuItem()
        let importChromeMenu = NSMenu()
        importCookiesItem = addItem(
            to: importChromeMenu,
            action: #selector(importCookiesAction),
            key: ""
        )
        importBookmarksItem = addItem(
            to: importChromeMenu,
            action: #selector(importBookmarksAction),
            key: ""
        )
        importChromeItem.submenu = importChromeMenu
        menu.addItem(importChromeItem)

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

    private func updateToggleShortcut() {
        let hotKey = settings.hotKey
        let name = HotKeyConfig.keyName(for: hotKey.keyCode)
        if hotKey.keyCode == UInt32(kVK_Space) {
            toggleItem.keyEquivalent = " "
        } else if name.count == 1 {
            toggleItem.keyEquivalent = name.lowercased()
        } else {
            toggleItem.keyEquivalent = ""
        }

        var modifiers: NSEvent.ModifierFlags = []
        if hotKey.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if hotKey.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if hotKey.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if hotKey.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        toggleItem.keyEquivalentModifierMask = modifiers
    }

    @objc private func toggleAction() { onToggle() }
    @objc private func pinAction() { onTogglePin() }
    @objc private func autoHideAction(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let policy = AutoHidePolicy(rawValue: rawValue)
        else { return }
        settings.autoHidePolicy = policy
        settings.persist()
    }
    @objc private func importCookiesAction() { onImportCookies() }
    @objc private func importBookmarksAction() { onImportBookmarks() }
    @objc private func prefsAction() { onPreferences() }
    @objc private func quitAction() { onQuit() }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let loc = settings.strings
        toggleItem.title = isPanelVisible() ? loc.hidePeekr : loc.showPeekr
        updateToggleShortcut()
        pinItem.title = loc.pinOpen
        pinItem.state = model.isPinned ? .on : .off
        autoHideItem.title = loc.autoHideMenu
        for policy in AutoHidePolicy.allCases {
            autoHideItems[policy]?.title = loc.autoHidePolicyName(policy)
            autoHideItems[policy]?.state =
                settings.autoHidePolicy == policy ? .on : .off
        }
        importChromeItem.title = loc.importFromChrome
        importCookiesItem.title = loc.importChromeCookies
        importBookmarksItem.title = loc.importChromeBookmarks
        prefsItem.title = loc.preferences
        quitItem.title = loc.quit
    }
}
