import SwiftUI
import AppKit
import Inject

/// Floating glass omnibox: drag grip, back/forward/reload, address field with a
/// Chrome-style autocomplete dropdown, bookmarks and open-externally buttons.
struct NavigationBar: View {
    let state: BrowserState
    let manager: WebViewManager
    let settings: Settings
    let model: AppModel
    let bookmarks: BookmarksModel
    let icons: IconStore
    let showsSidebarToggle: Bool
    let sidebarOnLeft: Bool

    var onMoveBegan: () -> Void
    var onMoveChanged: (CGSize) -> Void
    var onMoveEnded: () -> Void
    var onToggleSidebar: () -> Void
    /// Reports download-center visibility so the panel can suspend auto-hide
    /// while the popover is interactive (same treatment as sheets).
    var onDownloadsOpenChange: (Bool) -> Void = { _ in }

    private struct OmniboxBoundsKey: PreferenceKey {
        static var defaultValue: Anchor<CGRect>?

        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = nextValue() ?? value
        }
    }

    private struct DownloadButtonBoundsKey: PreferenceKey {
        static var defaultValue: Anchor<CGRect>?

        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = nextValue() ?? value
        }
    }

    @State private var text = ""
    @State private var isDragging = false
    @State private var suggestions: [OmniboxSuggestion] = []
    @State private var selectedIndex: Int?
    @State private var originalTypedText: String?
    @State private var userHasEdited = false
    @ObserveInjection private var inject
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestTask: Task<Void, Never>?
    /// Set while a chosen candidate is being written into the field, so the
    /// resulting text change doesn't re-query suggestions and drop the selection.
    @State private var fillingFromSuggestion = false
    /// A tab switch owns the omnibox contents even while the field is focused.
    /// Without this guard, ⌘W after ⌘T leaves the closed tab's home-page
    /// URL over the newly activated page.
    @State private var shouldSyncFocusedAddress = false
    @State private var focused = false
    @State private var suggestionsHovered = false
    @State private var suggestionDismissTask: Task<Void, Never>?
    @State private var suggestionDismissPending = false
    @State private var downloadsOpen = false

    private var showSuggestions: Bool {
        !suggestions.isEmpty && (focused || suggestionsHovered || suggestionDismissPending)
    }

    var body: some View {
        bar
            .overlayPreferenceValue(OmniboxBoundsKey.self) { anchor in
                GeometryReader { proxy in
                    if showSuggestions, let anchor {
                        suggestionsList
                            .frame(width: proxy[anchor].width)
                            .offset(
                                x: proxy[anchor].minX,
                                y: proxy[anchor].maxY + Theme.popoverGap
                            )
                            .transition(Motion.popoverTransition(anchor: .top, reduceMotion: reduceMotion))
                            .zIndex(10)
                    }
                }
            }
            .animation(
                reduceMotion ? nil : (showSuggestions ? Motion.dropdownOpen : Motion.dropdownClose),
                value: showSuggestions
            )
            .overlayPreferenceValue(DownloadButtonBoundsKey.self) { anchor in
                GeometryReader { proxy in
                    if downloadsOpen, let anchor {
                        DownloadCenter(
                            downloads: manager.downloads,
                            settings: settings,
                            onCancel: manager.cancelDownload,
                            onRemove: manager.downloads.remove,
                            onDismiss: { downloadsOpen = false },
                            onShowAll: {
                                downloadsOpen = false
                                manager.openInternalPage(.downloads)
                            }
                        )
                        .offset(
                            x: proxy[anchor].maxX - Theme.downloadCenterWidth,
                            y: proxy[anchor].maxY + Theme.popoverGap
                        )
                        .transition(Motion.popoverTransition(anchor: .topTrailing, reduceMotion: reduceMotion))
                        .zIndex(20)
                    }
                }
            }
        .animation(
            reduceMotion ? nil : (downloadsOpen ? Motion.dropdownOpen : Motion.dropdownClose),
            value: downloadsOpen
        )
        .onChange(of: downloadsOpen) { _, open in onDownloadsOpenChange(open) }
        .onAppear { syncText() }
        .onChange(of: focused) { _, isFocused in
            // Web addresses keep their uncommitted text on blur. Internal pages
            // restore their presentation value so private routes never linger.
            if isFocused {
                // The omnibox dropdown and the download center share the same
                // top chrome space; never leave two popovers competing there.
                downloadsOpen = false
                suggestionDismissTask?.cancel()
                suggestionDismissTask = nil
                suggestionDismissPending = false
                updateSuggestions()
            } else {
                shouldSyncFocusedAddress = false
                if state.internalPage != nil { syncText() }
                scheduleSuggestionDismissal()
            }
        }
        .onChange(of: text) { _, _ in
            if fillingFromSuggestion { fillingFromSuggestion = false; return }
            updateSuggestions()
        }
        .onChange(of: state.currentID) { _, _ in
            shouldSyncFocusedAddress = true
            syncText()
            if focused { updateSuggestions() }
        }
        .onChange(of: state.urlString) { _, _ in
            if !focused || shouldSyncFocusedAddress {
                syncText()
                shouldSyncFocusedAddress = false
            }
        }
        .onChange(of: state.internalPage) { _, _ in
            shouldSyncFocusedAddress = true
            syncText()
            if focused { updateSuggestions() }
        }
        .enableInjection()
    }

    private var bar: some View {
        HStack(spacing: 6) {
            grip
            navButton(
                "chevron.backward",
                enabled: state.internalPage != nil || state.canGoBack
            ) { manager.goBack() }
            navButton(
                "chevron.forward",
                enabled: state.internalPage == nil && state.canGoForward
            ) { manager.goForward() }
            navButton(
                state.internalPage == nil && state.isLoading ? "xmark" : "arrow.clockwise",
                enabled: state.internalPage == nil
            ) { manager.reloadOrStop() }
            omnibox
            bookmarkButton
            downloadButton
            if state.blockedPopupCount > 0 {
                popupIndicator
            }
            navButton("bookmark", enabled: true) {
                manager.openInternalPage(.bookmarks)
            }
            navButton(
                "safari",
                enabled: state.internalPage == nil && !state.urlString.isEmpty
            ) { openExternally() }
            overflowMenu
            if showsSidebarToggle {
                sidebarToggle
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        // Non-interactive glass: the interactive variant lifts the capsule with a
        // heavier shadow than the web card's, which looked inconsistent.
        .liquidGlass(in: Capsule(style: .continuous))
        .overlay(alignment: .bottom) { progressLine }
    }

    // MARK: - Pieces

    private var sidebarToggle: some View {
        Button(action: onToggleSidebar) {
            Image(systemName: sidebarOnLeft ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help(settings.strings.expandSidebar)
        .accessibilityLabel(settings.strings.expandSidebar)
        .animation(reduceMotion ? nil : Motion.sidebarStyle, value: sidebarOnLeft)
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 22, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isDragging { isDragging = true; onMoveBegan() }
                        onMoveChanged(value.translation)
                    }
                    .onEnded { _ in isDragging = false; onMoveEnded() }
            )
            .pointerCursor(isDragging ? .closedHand : .openHand)
            .help(settings.strings.dragHint)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : Motion.iconSwap, value: symbol)
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
    }

    private var downloadButton: some View {
        let downloads = manager.downloads
        return Button { downloadsOpen.toggle() } label: {
            Image(systemName: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if downloads.activeCount > 0 {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help(settings.strings.downloads)
        .accessibilityLabel(settings.strings.downloads)
        .anchorPreference(key: DownloadButtonBoundsKey.self, value: .bounds) { $0 }
    }

    private var bookmarkButton: some View {
        let urlString = state.urlString
        let isBookmarked = !urlString.isEmpty && bookmarks.bookmark(for: urlString) != nil
        let enabled = state.internalPage == nil && !urlString.isEmpty
        let label = isBookmarked ? settings.strings.bookmarks : settings.strings.addCurrentPage

        return Button(action: toggleBookmark) {
            Image(systemName: isBookmarked ? "star.fill" : "star")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : Motion.iconSwap, value: isBookmarked)
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isBookmarked ? .isSelected : AccessibilityTraits())
    }

    private var popupIndicator: some View {
        Menu {
            Text(settings.strings.popupsBlocked(state.blockedPopupCount))
            Button(settings.strings.allowPopups) {
                settings.blockPopups = false
                settings.persist()
                manager.clearBlockedPopups()
            }
        } label: {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(IconButtonStyle())
        .fixedSize()
        .foregroundStyle(.primary)
        .help(settings.strings.popupsBlocked(state.blockedPopupCount))
        .accessibilityLabel(settings.strings.popupsBlocked(state.blockedPopupCount))
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                manager.toggleTabSearch()
            } label: {
                Label(settings.strings.tabSearch, systemImage: "magnifyingglass")
            }
            Button {
                manager.openInternalPage(.history)
            } label: {
                Label(settings.strings.history, systemImage: "clock")
            }
            Button {
                manager.openInternalPage(.downloads)
            } label: {
                Label(settings.strings.downloads, systemImage: "arrow.down.circle")
            }
            Button {
                manager.openInternalPage(.bookmarks)
            } label: {
                Label(settings.strings.bookmarksManager, systemImage: "bookmark")
            }
            Button {
                manager.openInternalPage(.siteSettings(""))
            } label: {
                Label(settings.strings.siteSettings, systemImage: "hand.raised")
            }
            Button {
                manager.openInternalPage(.clearData)
            } label: {
                Label(settings.strings.clearBrowsingData, systemImage: "trash")
            }
            Button {
                manager.openInternalPage(.shortcuts)
            } label: {
                Label(settings.strings.shortcuts, systemImage: "keyboard")
            }
            Divider()
            Button {
                manager.toggleDevTools()
            } label: {
                Label(settings.strings.inspect, systemImage: "hammer")
            }
            .disabled(state.internalPage != nil)
            Button {
                manager.viewSource()
            } label: {
                Label(
                    settings.strings.viewSource,
                    systemImage: "chevron.left.forwardslash.chevron.right"
                )
            }
            .disabled(state.internalPage != nil)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(IconButtonStyle())
        .fixedSize()
        .foregroundStyle(.primary)
        .help(settings.strings.moreActions)
        .accessibilityLabel(settings.strings.moreActions)
    }

    private var omnibox: some View {
        HStack(spacing: 6) {
            securityIndicator

            OmniboxTextField(
                placeholder: settings.strings.omniboxPlaceholder,
                address: omniboxEditingAddress,
                pasteAndGoLabel: settings.strings.pasteAndGo,
                pasteAndSearchLabel: settings.strings.pasteAndSearch,
                text: $text,
                focused: $focused,
                focusRequest: state.focusOmniboxToken,
                onSubmit: { commit() },
                onMoveSelection: { moveSelection($0) },
                onEscape: {
                    guard showSuggestions else { return false }
                    clearSuggestions(); return true
                },
                onPasteAndGo: { clip in
                    clearSuggestions()
                    focused = false
                    manager.loadAddress(clip)
                }
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadcnFocusRing(focused, cornerRadius: 8)
        .anchorPreference(key: OmniboxBoundsKey.self, value: .bounds) { $0 }
    }

    private var securityIndicator: some View {
        Image(systemName: securitySymbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12)
            .help(securityLabel)
            .accessibilityLabel(securityLabel)
    }

    private var securitySymbol: String {
        if state.internalPage == .newTab { return "magnifyingglass" }
        if state.internalPage != nil { return "doc.text" }
        switch URL(string: state.urlString)?.scheme?.lowercased() {
        case "https": return "lock.fill"
        case "http": return "exclamationmark.triangle.fill"
        case "peekr", "file": return "doc.text"
        default: return "globe"
        }
    }

    private var securityLabel: String {
        if let page = state.internalPage {
            return settings.strings.title(for: page)
        }
        switch URL(string: state.urlString)?.scheme?.lowercased() {
        case "https":
            return settings.strings.secureConnection
        case "http":
            return settings.strings.notSecure
        default:
            if let host = URL(string: state.urlString)?.displayHost, !host.isEmpty {
                return host
            }
            let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? state.urlString : title
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        if state.internalPage == nil && state.isLoading && state.progress > 0.01 && state.progress < 1 {
            GeometryReader { geo in
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: geo.size.width * state.progress, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
            .offset(y: 1)
        }
    }

    // MARK: - Suggestions dropdown

    private var suggestionsList: some View {
        VStack(spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                suggestionRow(suggestion, highlighted: index == selectedIndex)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedIndex = index; commit() }
                    .onHover { if $0 { selectedIndex = index } }
            }
        }
        .padding(Theme.popoverPadding)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.suggestionCorner, style: .continuous))
        .onHover { isHovered in
            suggestionsHovered = isHovered
            if isHovered {
                suggestionDismissTask?.cancel()
                suggestionDismissTask = nil
                suggestionDismissPending = false
            } else if !focused {
                scheduleSuggestionDismissal()
            }
        }
    }

    private func suggestionRow(_ suggestion: OmniboxSuggestion, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            suggestionIcon(suggestion)
            Text(suggestion.primary)
                .font(.system(size: 12.5))
                .lineLimit(1)
            if let secondary = suggestion.secondary {
                Text(secondary)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.popoverContentInset)
        .padding(.vertical, Theme.popoverPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.suggestionRowCorner, style: .continuous)
                .fill(.primary.opacity(highlighted ? 0.1 : 0))
        )
    }

    /// The site's favicon for URL-bearing suggestions, falling back to the
    /// kind's SF symbol while loading or when there's no host (search rows).
    @ViewBuilder
    private func suggestionIcon(_ suggestion: OmniboxSuggestion) -> some View {
        if suggestion.kind != .search, let host = suggestionHost(suggestion) {
            Group {
                if let image = icons.image(forHost: host) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    symbolIcon(suggestion.kind)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onAppear { icons.load(host: host) }
        } else {
            symbolIcon(suggestion.kind).frame(width: 16)
        }
    }

    private func symbolIcon(_ kind: OmniboxSuggestion.Kind) -> some View {
        Image(systemName: icon(for: kind))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func suggestionHost(_ suggestion: OmniboxSuggestion) -> String? {
        let raw = suggestion.target.lowercased().hasPrefix("http") ? suggestion.target : "https://" + suggestion.target
        return URL(string: raw)?.host
    }

    private func icon(for kind: OmniboxSuggestion.Kind) -> String {
        switch kind {
        case .search: return "magnifyingglass"
        case .openURL: return "globe"
        case .tab: return "square.on.square"
        case .bookmark: return "bookmark"
        case .history: return "clock"
        }
    }

    // MARK: - Helpers

    private var omniboxEditingAddress: String {
        state.internalPage?.omniboxEditingAddress ?? state.urlString
    }

    private func syncText() {
        if let page = state.internalPage {
            if page == .newTab {
                text = ""
            } else {
                text = focused ? page.omniboxEditingAddress : settings.strings.title(for: page)
            }
        } else {
            text = focused ? state.urlString : state.displayURL
        }
    }

    private func toggleBookmark() {
        let urlString = state.urlString
        guard state.internalPage == nil, !urlString.isEmpty else { return }
        if let existing = bookmarks.bookmark(for: urlString) {
            bookmarks.remove(existing.id)
            return
        }
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.add(title: title.isEmpty ? urlString : title, urlString: urlString)
    }

    private func openExternally() {
        guard state.internalPage == nil, let url = URL(string: state.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func commit() {
        if let index = selectedIndex,
           suggestions.indices.contains(index),
           case .switchToTab(let tabID) = suggestions[index].action {
            clearSuggestions()
            focused = false
            model.select(tabID)
            manager.activate(tabID)
            return
        }
        let target = selectedIndex.flatMap { suggestions.indices.contains($0) ? suggestions[$0].target : nil } ?? text
        clearSuggestions()
        focused = false
        // ⌘Return opens in a background tab, like Chrome.
        if NSEvent.modifierFlags.contains(.command) {
            manager.loadAddressInBackgroundTab(target)
        } else {
            manager.loadAddress(target)
        }
    }

    /// Arrow through candidates, filling the chosen one into the field so the bar
    /// shows where Enter will go. Filling never navigates — only Enter does.
    private func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        let next = selectedIndex.map { ($0 + delta + count) % count } ?? (delta > 0 ? 0 : count - 1)
        selectedIndex = next
        fill(with: suggestions[next])
    }

    /// Write a candidate's target into the field. Guarded by `fillingFromSuggestion`
    /// so the text change doesn't re-run the suggestion query and reset the selection.
    private func fill(with suggestion: OmniboxSuggestion) {
        guard text != suggestion.target else { return }
        fillingFromSuggestion = true
        text = suggestion.target
    }

    private func updateSuggestions() {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard focused, !query.isEmpty else { clearSuggestions(); return }

        suggestions = OmniboxSuggestions.local(
            for: query, tabs: model.allTabs, bookmarks: bookmarks.roots,
            history: manager.historyEntries, currentTabID: state.currentID,
            searchLabel: settings.strings.searchWith(settings.searchEngine))
        // Chrome keeps the first suggestion active when the omnibox opens.
        selectedIndex = suggestions.isEmpty ? nil : 0

        suggestTask?.cancel()
        let engine = settings.searchEngine
        suggestTask = Task {
            do {
                try await Task.sleep(for: Motion.suggestionDismissGrace)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  engine == settings.searchEngine,
                  query == text.trimmingCharacters(in: .whitespaces)
            else { return }
            let completions = await OmniboxSuggestions.searchCompletions(for: query, using: engine)
            guard !Task.isCancelled,
                  engine == settings.searchEngine,
                  query == text.trimmingCharacters(in: .whitespaces)
            else { return }
            let existing = Set(suggestions.map { $0.target.lowercased() })
            suggestions.append(contentsOf: completions.filter { !existing.contains($0.target.lowercased()) })
        }
    }

    private func clearSuggestions() {
        suggestTask?.cancel()
        suggestionDismissTask?.cancel()
        suggestionDismissTask = nil
        suggestionDismissPending = false
        suggestionsHovered = false
        suggestions = []
        selectedIndex = nil
    }

    /// AppKit ends editing before SwiftUI delivers a click to a suggestion row.
    /// Defer blur dismissal briefly so the row remains alive long enough to
    /// receive the click, while clicks outside the dropdown still close it.
    private func scheduleSuggestionDismissal() {
        suggestionDismissTask?.cancel()
        suggestionDismissPending = true
        suggestionDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Motion.suggestionDismissGrace)
            } catch {
                return
            }
            guard !Task.isCancelled, !focused, !suggestionsHovered else {
                suggestionDismissPending = false
                suggestionDismissTask = nil
                return
            }
            suggestionDismissPending = false
            suggestionDismissTask = nil
            clearSuggestions()
        }
    }
}
