import AppKit

/// A borderless, non-activating floating panel that hosts the web content.
/// Non-activating means peeking it out won't steal focus from your current app,
/// yet it can still become key so you can type into web apps.
final class SlidePanel: NSPanel {
    /// Called only after the responder chain declines the close equivalents.
    var onCloseTabShortcut: (() -> Void)?
    var onCloseWindowShortcut: (() -> Void)?
    /// Handles the panel's quit equivalent before the application menu.
    var onQuitShortcut: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        // Keep the native floating-window separation. The content host owns
        // the rounded clip; this shadow is the only outer elevation effect.
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel owns close equivalents before CEF or the default responder
    /// chain can consume them without applying Peekr's tab/window semantics.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCloseWindowKeyEquivalent(
            flags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            onCloseWindowShortcut?()
            return true
        }
        if Self.isCloseTabKeyEquivalent(
            flags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            onCloseTabShortcut?()
            return true
        }
        if Self.isPlainCommandKeyEquivalent(
            flags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            character: "q"
        ) {
            onQuitShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isPlainCommandKeyEquivalent(
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        character: String
    ) -> Bool {
        let normalizedFlags = flags.intersection(.deviceIndependentFlagsMask)
        return normalizedFlags == [.command]
            && charactersIgnoringModifiers?.lowercased() == character.lowercased()
    }

    static func isCloseTabKeyEquivalent(
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        isPlainCommandKeyEquivalent(
            flags: flags,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            character: "w"
        )
    }

    static func isCloseWindowKeyEquivalent(
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
            && charactersIgnoringModifiers?.lowercased() == "w"
    }
}
