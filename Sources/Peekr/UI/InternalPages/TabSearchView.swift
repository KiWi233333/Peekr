import AppKit
import SwiftUI

/// Panel-wide cross-Space tab switcher (⌘⇧A). The shell presents this above the
/// browser layer and owns the actual workspace/tab switch; this view only
/// filters every Space's tabs, keeps keyboard focus in the search field, and
/// reports the chosen tab through `onSelect`.
struct TabSearchView: View {
    let model: AppModel
    let settings: Settings
    let icons: IconStore
    let onSelect: (UUID, WebApp.ID) -> Void
    let onClose: () -> Void
    let isPresented: Bool

    @State private var query = ""
    @State private var selectedTabID: WebApp.ID?
    @State private var hoveredTabID: WebApp.ID?
    @State private var focusRequest = 0
    @State private var searchFocused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loc: Localized { settings.strings }

    var body: some View {
        ZStack {
            Color.black.opacity(isPresented ? Layout.dimOpacity : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
                .animation(
                    reduceMotion ? nil : (isPresented ? Motion.dropdownOpen : Motion.dropdownClose),
                    value: isPresented
                )

            panel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focusRequest += 1
            resetSelection()
        }
        .onChange(of: resultIDs) { _, _ in normalizeSelection() }
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(loc.tabSearch))
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            searchHeader
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
                .accessibilityHidden(true)
            resultList
        }
        .frame(maxWidth: Layout.maxWidth)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: Theme.popoverCorner, style: .continuous),
            tint: .primary.opacity(0.03),
            interactive: true
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.popoverCorner, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: Theme.popoverCorner, style: .continuous))
        .padding(.horizontal, 24)
        .scaleEffect(reduceMotion ? 1 : (isPresented ? 1 : Motion.modalScale))
        .opacity(isPresented ? 1 : 0)
        .animation(
            reduceMotion ? nil : (isPresented ? Motion.dropdownOpen : Motion.dropdownClose),
            value: isPresented
        )
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TabSearchField(
                placeholder: loc.searchTabsPlaceholder,
                label: loc.searchTabs,
                text: $query,
                focused: $searchFocused,
                focusRequest: focusRequest,
                onSubmit: activateSelection,
                onMoveSelection: moveSelection,
                onEscape: dismiss
            )
            .frame(maxWidth: .infinity)
            .frame(height: 22)

            if !query.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(loc.clearSearch)
                .accessibilityLabel(loc.clearSearch)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            .primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        }
        .shadcnFocusRing(searchFocused, cornerRadius: Theme.controlCorner)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: query.isEmpty)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { entry in
                            resultRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(Theme.popoverPadding)
                }
                .frame(maxHeight: listMaxHeight)
                .onChange(of: selectedTabID) { _, _ in reveal(using: proxy) }
                .onChange(of: resultIDs) { _, _ in reveal(using: proxy) }
                .onAppear { reveal(using: proxy) }
            }
        }
    }

    private var listMaxHeight: CGFloat {
        min(
            CGFloat(max(results.count, 1)) * Layout.rowHeight + Theme.popoverPadding * 2,
            Layout.maxListHeight
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(loc.noMatchingTabs)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Layout.emptyHeight)
        .accessibilityElement(children: .combine)
    }

    private func resultRow(_ entry: Entry) -> some View {
        let isSelected = entry.id == selectedTabID
        let isHovered = entry.id == hoveredTabID

        return HStack(spacing: 10) {
            resultIcon(entry)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.tab.displayName)
                    .font(.system(size: 13, weight: entry.isCurrentTab ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if let host = entry.tab.host, !host.isEmpty {
                        Text(host)
                        separatorDot
                    }
                    Text(entry.workspaceName)
                        .fontWeight(entry.isCurrentWorkspace ? .semibold : .regular)
                        .padding(.horizontal, entry.isCurrentWorkspace ? 5 : 0)
                        .padding(.vertical, 1)
                        .background {
                            if entry.isCurrentWorkspace {
                                Capsule(style: .continuous)
                                    .fill(.primary.opacity(0.08))
                            }
                        }
                    if let groupName = entry.groupName {
                        separatorDot
                        Image(systemName: "square.stack")
                            .font(.system(size: 9, weight: .medium))
                            .accessibilityHidden(true)
                        Text(groupName)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if entry.isCurrentTab {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.suggestionRowCorner, style: .continuous)
                .fill(.primary.opacity(isSelected ? 0.11 : (isHovered ? 0.055 : 0)))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.suggestionRowCorner, style: .continuous)
                .stroke(Theme.hairline, lineWidth: isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { activate(entry) }
        .onHover { hovering in
            if hovering {
                hoveredTabID = entry.id
            } else if hoveredTabID == entry.id {
                hoveredTabID = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(rowAccessibilityLabel(entry)))
        .accessibilityHint(Text(loc.switchToTab))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
        .accessibilityAction { activate(entry) }
    }

    private func resultIcon(_ entry: Entry) -> some View {
        Group {
            if let image = icons.image(for: entry.tab) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onAppear { icons.load(entry.tab) }
        .accessibilityHidden(true)
    }

    private var separatorDot: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Entries

    private struct Entry: Identifiable {
        let tab: WebApp
        let workspaceID: UUID
        let workspaceName: String
        let groupName: String?
        let isCurrentWorkspace: Bool
        let isCurrentTab: Bool

        var id: WebApp.ID { tab.id }

        var searchableText: [String] {
            [tab.displayName, tab.title, tab.urlString, workspaceName, groupName ?? ""]
        }
    }

    private var entries: [Entry] {
        model.orderedWorkspaces.flatMap { workspace -> [Entry] in
            let workspaceName = displayName(for: workspace)
            let tabsByID = Dictionary(
                workspace.tabs.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            return workspace.orderedTabIDs.compactMap { tabID -> Entry? in
                guard let tab = tabsByID[tabID] else { return nil }
                let groupName = workspace.group(containing: tabID).map { group -> String in
                    let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return name.isEmpty ? loc.tabGroup : name
                }
                return Entry(
                    tab: tab,
                    workspaceID: workspace.id,
                    workspaceName: workspaceName,
                    groupName: groupName,
                    isCurrentWorkspace: workspace.id == model.activeWorkspaceID,
                    isCurrentTab: workspace.id == model.activeWorkspaceID && tabID == model.selectedID
                )
            }
        }
    }

    private var results: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            entry.searchableText.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var resultIDs: [WebApp.ID] { results.map(\.id) }

    private var selectedEntry: Entry? {
        guard let selectedTabID else { return nil }
        return results.first { $0.id == selectedTabID }
    }

    private func displayName(for workspace: Workspace) -> String {
        let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return workspace.isAgentOwned ? loc.defaultAgentWorkspace : loc.defaultWorkspace
    }

    // MARK: - Selection and actions

    private func resetSelection() {
        let entries = results
        if let current = model.selectedID, entries.contains(where: { $0.id == current }) {
            selectedTabID = current
        } else {
            selectedTabID = entries.first?.id
        }
    }

    private func normalizeSelection() {
        let entries = results
        guard !entries.isEmpty else {
            selectedTabID = nil
            return
        }
        if let selectedTabID, entries.contains(where: { $0.id == selectedTabID }) { return }
        selectedTabID = entries.first?.id
    }

    private func moveSelection(_ delta: Int) {
        let entries = results
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selectedTabID }
            ?? (delta > 0 ? -1 : entries.count)
        let next = (current + delta + entries.count) % entries.count
        selectedTabID = entries[next].id
    }

    private func reveal(using proxy: ScrollViewProxy) {
        guard let selectedTabID else { return }
        if reduceMotion {
            proxy.scrollTo(selectedTabID)
        } else {
            withAnimation(Motion.controlFeedback) {
                proxy.scrollTo(selectedTabID)
            }
        }
    }

    private func activateSelection() {
        guard let entry = selectedEntry ?? results.first else { return }
        activate(entry)
    }

    private func activate(_ entry: Entry) {
        selectedTabID = entry.id
        onSelect(entry.workspaceID, entry.id)
    }

    private func clearSearch() {
        query = ""
        focusRequest += 1
    }

    private func dismiss() {
        onClose()
    }

    private func rowAccessibilityLabel(_ entry: Entry) -> String {
        var parts = [entry.tab.displayName]
        if let host = entry.tab.host, !host.isEmpty { parts.append(host) }
        parts.append(entry.workspaceName)
        if let groupName = entry.groupName { parts.append(groupName) }
        if entry.isCurrentTab {
            parts.append(loc.currentTab)
        } else if entry.isCurrentWorkspace {
            parts.append(loc.currentWorkspace)
        }
        return parts.joined(separator: ", ")
    }

    private enum Layout {
        static let maxWidth: CGFloat = 560
        static let maxListHeight: CGFloat = 356
        static let rowHeight: CGFloat = 50
        static let emptyHeight: CGFloat = 112
        static let dimOpacity: Double = 0.22
    }
}

/// The search field keeps AppKit's field editor so arrow keys, Return and Esc
/// are intercepted before the text system consumes them, while IME composition
/// is left alone.
private struct TabSearchField: NSViewRepresentable {
    let placeholder: String
    let label: String
    @Binding var text: String
    @Binding var focused: Bool
    let focusRequest: Int
    let onSubmit: () -> Void
    let onMoveSelection: (Int) -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(label)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)

        let editor = field.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
            editor?.string = text
        }

        guard coordinator.focusRequest != focusRequest else { return }
        coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { [weak field, weak coordinator] in
            guard let field, let coordinator,
                  coordinator.focusRequest == focusRequest,
                  let window = field.window else { return }
            if field.currentEditor() == nil {
                window.makeFirstResponder(field)
            }
            field.currentEditor()?.selectAll(nil)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextField,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: nsView.intrinsicContentSize.height
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TabSearchField
        var focusRequest: Int

        init(_ parent: TabSearchField) {
            self.parent = parent
            // One less than the first request makes the initial update focus
            // the field even before `onAppear` can bump the token.
            focusRequest = parent.focusRequest - 1
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.focused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
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
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

/// Labels used by the tab switcher that are not part of the shared string
/// table yet. Keeping them here lets this file land without editing
/// `Localization.swift`.
