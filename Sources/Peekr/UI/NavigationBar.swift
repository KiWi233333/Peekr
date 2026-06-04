import SwiftUI

/// Floating glass omnibox: drag grip, back/forward/reload, address field with a
/// Chrome-style autocomplete dropdown, bookmarks and open-externally buttons.
struct NavigationBar: View {
    let state: BrowserState
    let manager: WebViewManager
    let settings: Settings
    let model: AppModel
    let bookmarks: BookmarksModel

    var onMoveBegan: () -> Void
    var onMoveChanged: (CGSize) -> Void
    var onMoveEnded: () -> Void
    var onBookmarks: () -> Void

    @State private var text = ""
    @State private var isDragging = false
    @State private var suggestions: [OmniboxSuggestion] = []
    @State private var selectedIndex: Int?
    @State private var suggestTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var showSuggestions: Bool { focused && !suggestions.isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            bar
            if showSuggestions { suggestionsList }
        }
        .onAppear { syncText() }
        .onChange(of: focused) { _, isFocused in
            text = isFocused ? state.urlString : state.displayURL
            if isFocused { updateSuggestions() } else { clearSuggestions() }
        }
        .onChange(of: text) { _, _ in updateSuggestions() }
        .onChange(of: state.urlString) { _, _ in if !focused { syncText() } }
        .onChange(of: state.focusOmniboxToken) { _, _ in focused = true }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            grip
            navButton("chevron.backward", enabled: state.canGoBack) { manager.goBack() }
            navButton("chevron.forward", enabled: state.canGoForward) { manager.goForward() }
            navButton(state.isLoading ? "xmark" : "arrow.clockwise", enabled: true) { manager.reloadOrStop() }
            omnibox
            navButton("bookmark", enabled: true) { onBookmarks() }
            navButton("safari", enabled: !state.urlString.isEmpty) { openExternally() }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule(style: .continuous), interactive: true)
        .overlay(alignment: .bottom) { progressLine }
    }

    // MARK: - Pieces

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
            .help(settings.strings.dragHint)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
    }

    private var omnibox: some View {
        TextField(settings.strings.omniboxPlaceholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1)
            .focused($focused)
            .onSubmit { commit() }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.escape) {
                guard showSuggestions else { return .ignored }
                clearSuggestions(); return .handled
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private var progressLine: some View {
        if state.isLoading && state.progress > 0.01 && state.progress < 1 {
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
        .padding(5)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 6)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(highlighted ? 0.1 : 0))
        )
    }

    /// The site's favicon for URL-bearing suggestions, falling back to the
    /// kind's SF symbol while loading or when there's no host (search rows).
    @ViewBuilder
    private func suggestionIcon(_ suggestion: OmniboxSuggestion) -> some View {
        if suggestion.kind != .search, let host = suggestionHost(suggestion),
           let url = IconStore.faviconURL(host: host) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    symbolIcon(suggestion.kind)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
        }
    }

    // MARK: - Helpers

    private func syncText() {
        text = focused ? state.urlString : state.displayURL
    }

    private func openExternally() {
        guard let url = URL(string: state.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func commit() {
        let target = selectedIndex.flatMap { suggestions.indices.contains($0) ? suggestions[$0].target : nil } ?? text
        clearSuggestions()
        focused = false
        manager.loadAddress(target)
    }

    private func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        if let index = selectedIndex {
            selectedIndex = (index + delta + count) % count
        } else {
            selectedIndex = delta > 0 ? 0 : count - 1
        }
    }

    private func updateSuggestions() {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard focused, !query.isEmpty, query != state.urlString else { clearSuggestions(); return }

        suggestions = OmniboxSuggestions.local(
            for: query, tabs: model.allTabs, bookmarks: bookmarks.roots,
            searchLabel: settings.strings.googleSearch)
        selectedIndex = nil

        suggestTask?.cancel()
        suggestTask = Task {
            let completions = await OmniboxSuggestions.searchCompletions(for: query)
            guard !Task.isCancelled, query == text.trimmingCharacters(in: .whitespaces) else { return }
            let existing = Set(suggestions.map { $0.target.lowercased() })
            suggestions.append(contentsOf: completions.filter { !existing.contains($0.target.lowercased()) })
        }
    }

    private func clearSuggestions() {
        suggestTask?.cancel()
        suggestions = []
        selectedIndex = nil
    }
}
