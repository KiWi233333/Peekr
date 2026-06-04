import AppKit

/// Installs `NSApp.mainMenu`.
///
/// Peekr is an `LSUIElement`/`.accessory` agent with no on-screen menu bar of
/// its own — but the main menu is still what AppKit consults to route the
/// standard editing key equivalents (⌘X/⌘C/⌘V/⌘A/⌘Z) to the first responder.
/// Without an Edit menu those shortcuts are dead in *every* text field: the
/// omnibox's field editor and the WKWebView's inputs alike. Because the slide
/// panel can become key (`canBecomeKey`), `sendEvent` walks this menu's
/// `performKeyEquivalent` even though the app never activates, so editing
/// shortcuts work without stealing focus from the frontmost app.
///
/// The items target the first responder (`nil`), so the same menu serves the
/// panel, the Preferences window, and any future window uniformly.
@MainActor
func installMainMenu(strings: Localized) {
    let mainMenu = NSMenu()

    // The first submenu is treated as the application menu by convention.
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
        withTitle: strings.quit,
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )

    // Edit menu — the reason this menu exists.
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: strings.editMenu)
    editItem.submenu = editMenu

    editMenu.addItem(withTitle: strings.undo, action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: strings.redo, action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: strings.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: strings.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: strings.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: strings.delete, action: #selector(NSText.delete(_:)), keyEquivalent: "")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: strings.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    NSApp.mainMenu = mainMenu
}
