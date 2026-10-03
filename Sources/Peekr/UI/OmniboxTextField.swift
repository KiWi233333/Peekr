import AppKit
import SwiftUI

/// A single-line address editor with browser-style focus selection on macOS 14+.
struct OmniboxTextField: NSViewRepresentable {
    let placeholder: String
    let address: String
    @Binding var text: String
    @Binding var focused: Bool
    let focusRequest: Int
    var onSubmit: () -> Void
    var onMoveSelection: (Int) -> Void
    var onEscape: () -> Bool

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
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("omnibox")
        field.delegate = context.coordinator
        field.onBeginFocus = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            // Replace the abbreviated display URL before the click selects text.
            coordinator.parent.text = coordinator.parent.address
            coordinator.parent.focused = true
            field.stringValue = coordinator.parent.address
            field.prepareForFocusSelection()
        }
        return field
    }

    func updateNSView(_ field: OmniboxNativeTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            // Leave SwiftUI's update pass before changing the first responder.
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator,
                    coordinator.focusRequest == focusRequest,
                    let window = field.window
                else { return }
                if field.currentEditor() == nil { window.makeFirstResponder(field) }
                field.prepareForFocusSelection()
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
    final class Coordinator: NSObject, NSTextFieldDelegate {
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
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit()
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
            return true
        }
    }
}

final class OmniboxNativeTextField: NSTextField {
    var onBeginFocus: (() -> Void)?
    private var selectionRequest = 0

    func selectAllText() {
        currentEditor()?.selectAll(nil)
    }

    /// AppKit can create the field editor and apply its click selection in
    /// separate turns. Select immediately, then retry once the editor exists so
    /// a first click cannot leave only a caret or partial selection behind.
    func prepareForFocusSelection() {
        selectionRequest &+= 1
        let request = selectionRequest
        selectAllText()
        selectAllTextWhenReady(request: request, attempts: 3)
    }

    private func selectAllTextWhenReady(request: Int, attempts: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionRequest == request else { return }
            guard let editor = self.currentEditor() else {
                guard attempts > 0 else { return }
                self.selectAllTextWhenReady(request: request, attempts: attempts - 1)
                return
            }
            guard self.window?.firstResponder === editor else { return }
            editor.selectAll(nil)
        }
    }

    private func cancelPendingSelection() {
        selectionRequest &+= 1
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBeginFocus?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        let editor = currentEditor()
        let isEditing = editor != nil && window?.firstResponder === editor
        let selectsOnClick =
            !isEditing && event.clickCount == 1
            && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        cancelPendingSelection()
        super.mouseDown(with: event)
        // AppKit finishes its click tracking first. A drag or double-click keeps
        // its own selection; subsequent clicks keep ordinary caret placement.
        if selectsOnClick {
            prepareForFocusSelection()
        }
    }
}
