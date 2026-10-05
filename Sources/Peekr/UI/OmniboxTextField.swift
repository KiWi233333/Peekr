import AppKit
import SwiftUI

/// A single-line address editor with browser-style focus selection on macOS 14+.
struct OmniboxTextField: NSViewRepresentable {
    let placeholder: String
    let address: String
    var pasteAndGoLabel: String = "Paste and Go"
    var pasteAndSearchLabel: String = "Paste and Search"
    @Binding var text: String
    @Binding var focused: Bool
    let focusRequest: Int
    var onSubmit: () -> Void
    var onMoveSelection: (Int) -> Void
    var onEscape: () -> Bool
    var onPasteAndGo: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> OmniboxNativeTextField {
        let field = OmniboxNativeTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("omnibox")
        field.delegate = context.coordinator
        field.onBeginFocus = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.parent.text = coordinator.parent.address
            coordinator.parent.focused = true
            field.stringValue = coordinator.parent.address
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: OmniboxNativeTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)

        let editor = field.currentEditor() as? NSTextView
        let isComposing = editor?.hasMarkedText() == true

        // Protect IME composition: never overwrite stringValue while user is composing.
        if !isComposing && field.stringValue != text {
            field.stringValue = text
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator,
                    coordinator.focusRequest == focusRequest,
                    let window = field.window
                else { return }
                coordinator.parent.text = coordinator.parent.address
                coordinator.parent.focused = true
                field.stringValue = coordinator.parent.address
                if field.currentEditor() == nil {
                    window.makeFirstResponder(field)
                }
                field.currentEditor()?.selectAll(nil)
            }
        } else if !focused, field.currentEditor() != nil {
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator, !coordinator.parent.focused,
                    field.currentEditor() != nil
                else { return }
                field.window?.makeFirstResponder(nil)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OmniboxNativeTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
        var parent: OmniboxTextField
        var focusRequest: Int

        init(_ parent: OmniboxTextField) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.focused = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Let an input method finish composition before handling navigation.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let clip = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !clip.isEmpty
            else {
                return menu
            }
            let isURL = clip.lowercased().hasPrefix("http://")
                || clip.lowercased().hasPrefix("https://")
                || (!clip.contains(" ") && clip.contains("."))
            let title = isURL ? parent.pasteAndGoLabel : parent.pasteAndSearchLabel
            let item = NSMenuItem(title: title, action: #selector(pasteAndGoAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = clip

            if let pasteIndex = menu.items.firstIndex(where: { $0.action == #selector(NSText.paste(_:)) }) {
                menu.insertItem(item, at: pasteIndex + 1)
            } else {
                menu.addItem(item)
            }
            return menu
        }

        @objc private func pasteAndGoAction(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            parent.onPasteAndGo(text)
        }
    }
}

final class OmniboxNativeTextField: NSTextField {
    var onBeginFocus: (() -> Void)?
    private var wasEditingOnMouseDown = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBeginFocus?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        let editor = currentEditor()
        wasEditingOnMouseDown = (editor != nil && window?.firstResponder === editor)
        super.mouseDown(with: event)
        if !wasEditingOnMouseDown && event.clickCount == 1 {
            if let ed = currentEditor(), ed.selectedRange.length == 0 {
                ed.selectAll(nil)
            }
        }
    }
}
