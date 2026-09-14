import AppKit
import SwiftUI

/// Native contextual menu bridge for a tab-group header. Left-click and drag
/// events pass through to SwiftUI; only a right-click/control-click is captured.
struct TabGroupContextMenuOverlay: NSViewRepresentable {
    let group: TabGroup
    let strings: Localized
    var onRename: (String) -> Void
    var onRecolor: (TabGroupColor) -> Void
    var onCustomColor: (TabGroupCustomColor) -> Void
    var onNewTab: () -> Void
    var onDuplicate: () -> Void
    var onClose: () -> Void
    var onUngroup: () -> Void

    func makeNSView(context: Context) -> TabGroupContextMenuView {
        let view = TabGroupContextMenuView()
        view.menuProvider = makeMenu
        return view
    }

    func updateNSView(_ nsView: TabGroupContextMenuView, context: Context) {
        nsView.menuProvider = makeMenu
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: strings.tabGroup)
        menu.autoenablesItems = false

        let editorItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
        let editor = TabGroupMenuEditor(
            name: group.name,
            color: group.color,
            customColor: group.customColor,
            strings: strings,
            onRename: onRename,
            onRecolor: onRecolor,
            onCustomColor: onCustomColor
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        editorItem.view = hostingView
        menu.addItem(editorItem)
        menu.addItem(.separator())

        menu.addItem(
            TabGroupMenuActionItem(
                title: strings.newTabInGroup,
                systemImage: "plus.square.on.square",
                handler: onNewTab
            )
        )
        menu.addItem(
            TabGroupMenuActionItem(
                title: strings.duplicateGroup,
                systemImage: "plus.square.on.square",
                handler: onDuplicate
            )
        )
        menu.addItem(
            TabGroupMenuActionItem(
                title: strings.closeGroup,
                systemImage: "rectangle.badge.xmark",
                handler: onClose
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            TabGroupMenuActionItem(
                title: strings.ungroup,
                systemImage: "rectangle.3.group.bubble.left",
                handler: onUngroup
            )
        )
        return menu
    }
}

final class TabGroupContextMenuView: NSView {
    var menuProvider: () -> NSMenu = { NSMenu() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let event = NSApp.currentEvent
        let rightButtonDown = event?.type == .rightMouseDown
            || NSEvent.pressedMouseButtons & 0b10 != 0
        let controlClick = event?.type == .leftMouseDown
            && event?.modifierFlags.contains(.control) == true
        return rightButtonDown || controlClick ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }
}

private final class TabGroupMenuActionItem: NSMenuItem {
    private var handler: () -> Void

    init(title: String, systemImage: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self
        action = #selector(performAction)
        image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        image?.isTemplate = true
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
        target = self
        action = #selector(performAction)
    }

    @objc private func performAction() {
        handler()
    }
}

private struct TabGroupMenuEditor: View {
    let strings: Localized
    var onRename: (String) -> Void
    var onRecolor: (TabGroupColor) -> Void
    var onCustomColor: (TabGroupCustomColor) -> Void

    @State private var name: String
    @State private var color: Color
    @State private var selectedPreset: TabGroupColor?
    @FocusState private var nameFocused: Bool

    init(
        name: String,
        color: TabGroupColor,
        customColor: TabGroupCustomColor?,
        strings: Localized,
        onRename: @escaping (String) -> Void,
        onRecolor: @escaping (TabGroupColor) -> Void,
        onCustomColor: @escaping (TabGroupCustomColor) -> Void
    ) {
        self.strings = strings
        self.onRename = onRename
        self.onRecolor = onRecolor
        self.onCustomColor = onCustomColor
        _name = State(initialValue: name)
        _color = State(initialValue: customColor?.tint ?? color.tint)
        _selectedPreset = State(initialValue: customColor == nil ? color : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(strings.tabGroup, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .noFocusRing()
                .onSubmit { onRename(name) }
                .onChange(of: name) { _, newValue in onRename(newValue) }

            HStack(spacing: 5) {
                ForEach(TabGroupColor.palette, id: \.self) { option in
                    Button {
                        selectedPreset = option
                        color = option.tint
                        onRecolor(option)
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(option == selectedPreset ? option.tint : .clear, lineWidth: 2)
                                .frame(width: 22, height: 22)
                            Circle()
                                .fill(option.tint)
                                .frame(width: 16, height: 16)
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(option.displayName(chinese: strings.isChinese))
                    .accessibilityLabel(option.displayName(chinese: strings.isChinese))
                    .accessibilityAddTraits(option == selectedPreset ? .isSelected : [])
                }
            }

            ColorPicker(
                strings.customColor,
                selection: Binding(
                    get: { color },
                    set: { newColor in
                        color = newColor
                        selectedPreset = nil
                        guard let customColor = TabGroupCustomColor(color: newColor) else { return }
                        onCustomColor(customColor)
                    }
                ),
                supportsOpacity: false
            )
            .font(.system(size: 12))
        }
        .padding(10)
        .frame(width: 270, alignment: .leading)
        .onAppear { nameFocused = true }
    }
}
