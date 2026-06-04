import AppKit
import Carbon.HIToolbox

/// C-compatible Carbon callback. Carbon hotkeys fire on the main run loop.
private func peekrHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hkID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    GlobalHotKeyCenter.shared.handle(id: hkID.id)
    return noErr
}

/// Registers global hotkeys via Carbon and dispatches presses to closures.
/// Supports re-binding the primary shortcut when preferences change.
final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()

    private let signature: OSType = 0x50454B52 // 'PEKR'
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// Re-bind the single primary toggle hotkey.
    func setPrimary(_ config: HotKeyConfig, action: @escaping () -> Void) {
        unregisterAll()
        register(keyCode: config.keyCode, modifiers: config.modifiers, action: action)
    }

    func handle(id: UInt32) {
        handlers[id]?()
    }

    // MARK: - Private

    private func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = action

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        if RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs[id] = ref
        }
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), peekrHotKeyHandler, 1, &spec, nil, nil)
    }
}

/// Maps Cocoa modifier flags to a Carbon modifier mask (for the recorder).
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    return mask
}
