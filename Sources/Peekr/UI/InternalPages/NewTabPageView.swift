import AppKit
import SwiftUI

struct NewTabPageView: View {
    let history: HistoryStore
    let bookmarks: BookmarksModel
    let settings: Settings
    let icons: IconStore
    let onSearch: (String) -> Void
    let onOpen: (URL) -> Void
    let onManageBookmarks: () -> Void

    @State private var query = ""
    @State private var appeared = false
    @State private var appearanceOpen = false
    @State private var selectedFolderID: UUID?
    @State private var addingShortcut = false
    @State private var shortcutTitle = ""
    @State private var shortcutURL = ""
    @State private var shortcutError: String?
    @State private var scrollOffset: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme

    private enum Layout {
        static let contentMaxWidth: CGFloat = 1160
        static let horizontalPadding: CGFloat = 30
    }

    private var loc: Localized { settings.strings }
    private var recentSites: [HistoryEntry] { history.topSites(limit: 6) }
    private var selectedFolder: BookmarkNode? {
        guard let selectedFolderID else { return nil }
        return Self.folder(id: selectedFolderID, in: bookmarks.roots)
    }
    private var bookmarkNodes: [BookmarkNode] {
        selectedFolder?.children ?? bookmarks.roots
    }
    private var activeWallpaper: NewTabWallpaper {
        NewTabWallpaperCatalog.item(id: settings.newTabWallpaperID)
    }
    private var resolvedColorScheme: ColorScheme {
        guard settings.newTabWallpaperEnabled else { return systemColorScheme }
        if settings.newTabUsesCustomWallpaper { return systemColorScheme }
        return activeWallpaper.isDark ? .dark : .light
    }

    var body: some View {
        ZStack {
            wallpaperBackground
            GeometryReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            topContent
                                .padding(.top, max(42, proxy.size.height * 0.12))
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 12)
                            Spacer(minLength: 72)
                            dock
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 16)
                            if hasDetailContent {
                                scrollHint(reader: reader)
                                detailContent
                                    .id("newTabDetails")
                            }
                        }
                        .frame(width: proxy.size.width)
                        .frame(minHeight: proxy.size.height)
                        .background {
                            GeometryReader { contentProxy in
                                Color.clear.preference(
                                    key: NewTabScrollOffsetKey.self,
                                    value: contentProxy.frame(in: .named("newTabScroll")).minY
                                )
                            }
                        }
                    }
                    .coordinateSpace(name: "newTabScroll")
                    .scrollIndicators(.automatic)
                    .scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(NewTabScrollOffsetKey.self) { scrollOffset = $0 }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    appearanceControl
                        .padding(18)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, resolvedColorScheme)
        .onAppear(perform: reveal)
        .onChange(of: bookmarks.roots) { _, _ in
            if selectedFolderID != nil, selectedFolder == nil { selectedFolderID = nil }
        }
        .sheet(isPresented: $addingShortcut) { shortcutSheet }
    }

    private var wallpaperBackground: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if settings.newTabWallpaperEnabled,
                   let image = NewTabWallpaperCatalog.image(
                    selectedID: settings.newTabWallpaperID,
                    usesCustom: settings.newTabUsesCustomWallpaper,
                    customPath: settings.newTabCustomWallpaperPath
                   ) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(1.1)
                        .offset(y: parallaxOffset)
                        .clipped()
                    LinearGradient(
                        colors: [
                            overlayColor.opacity(settings.newTabWallpaperOverlay),
                            overlayColor.opacity(settings.newTabWallpaperOverlay * 0.36),
                            overlayColor.opacity(settings.newTabWallpaperOverlay * 0.78),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .ignoresSafeArea()
    }

    private var overlayColor: Color {
        resolvedColorScheme == .dark ? .black : .white
    }

    private var parallaxOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        return max(-140, min(0, scrollOffset) * 0.22)
    }

    private var topContent: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
                .accessibilityLabel("Peekr")
            searchField
                .frame(maxWidth: 620)
            HStack(spacing: 12) {
                Image(nsImage: BrandGlyph.image(size: 32))
                    .frame(width: 38, height: 38)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
                    .accessibilityHidden(true)
                Button { addingShortcut = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .light))
                        .frame(width: 38, height: 38)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(loc.newTabAddShortcut)
                .accessibilityLabel(loc.newTabAddShortcut)
            }
            .foregroundStyle(.primary.opacity(0.72))
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(loc.newTabSearchHint))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .focusEffectDisabled()
                .onSubmit(submit)
                .onExitCommand { query = "" }
                .accessibilityLabel(loc.newTabSearchHint)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(IconButtonStyle())
                .help(loc.clearSearch)
                .accessibilityLabel(loc.clearSearch)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 19, style: .continuous),
            interactive: true
        )
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(.primary.opacity(searchFocused ? 0.16 : 0), lineWidth: 0.8)
        }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: searchFocused)
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: query.isEmpty)
    }

    private var dock: some View {
        VStack(spacing: 26) {
            if settings.newTabShowBookmarks, !bookmarkNodes.isEmpty {
                bookmarkSection
            }
            if settings.newTabShowRecent, !recentSites.isEmpty {
                recentSection
            }
        }
        .frame(maxWidth: Layout.contentMaxWidth)
        .padding(.horizontal, Layout.horizontalPadding)
        .frame(maxWidth: .infinity)
    }

    private var hasDetailContent: Bool {
        (settings.newTabShowRecent && !history.entries.isEmpty)
            || (settings.newTabShowBookmarks && !bookmarks.isEmpty)
    }

    private var detailContent: some View {
        NewTabDetailContent(
            recent: Array(history.entries.prefix(6)),
            bookmarkLinks: Array(bookmarks.allBookmarks().prefix(12)),
            showRecent: settings.newTabShowRecent,
            showBookmarks: settings.newTabShowBookmarks,
            icons: icons,
            loc: loc,
            onOpen: open
        )
        .frame(maxWidth: Layout.contentMaxWidth)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 92)
        .frame(maxWidth: .infinity)
    }

    private func scrollHint(reader: ScrollViewProxy) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.dropdownOpen) {
                reader.scrollTo("newTabDetails", anchor: .top)
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .help(loc.newTabMoreContent)
        .accessibilityLabel(loc.newTabMoreContent)
        .padding(.top, 12)
        .opacity(appeared ? 1 : 0)
    }

    private var bookmarkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if selectedFolder != nil {
                    Button { selectedFolderID = nil } label: {
                        Label(loc.newTabBack, systemImage: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Text(selectedFolder?.title ?? loc.bookmarks)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.72))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onManageBookmarks) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(IconButtonStyle())
                .help(loc.newTabManageBookmarks)
                .accessibilityLabel(loc.newTabManageBookmarks)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 12, alignment: .top)],
                spacing: 12
            ) {
                ForEach(bookmarkNodes) { node in
                    NewTabBookmarkCard(node: node, icons: icons) {
                        if node.isFolder {
                            selectedFolderID = node.id
                        } else if let urlString = node.urlString {
                            open(urlString)
                        }
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.topSites)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.72))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 14, alignment: .top)],
                spacing: 16
            ) {
                ForEach(recentSites) { entry in
                    NewTabRecentCard(entry: entry, icons: icons) { open(entry.urlString) }
                }
            }
        }
    }

    private var appearanceControl: some View {
        Button { appearanceOpen.toggle() } label: {
            Image(systemName: appearanceOpen ? "xmark" : "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .liquidGlass(in: Circle(), interactive: true)
        .help(loc.newTabOpenAppearance)
        .accessibilityLabel(loc.newTabOpenAppearance)
        .accessibilityValue(appearanceOpen ? loc.close : loc.newTabOpenAppearance)
        .popover(isPresented: $appearanceOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            NewTabAppearanceView(settings: settings, isPresented: $appearanceOpen)
        }
        .zIndex(5)
    }

    private var shortcutSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(loc.newTabAddShortcut)
                .font(.headline)
            TextField(loc.newTabShortcutName, text: $shortcutTitle)
                .textFieldStyle(.roundedBorder)
            TextField(loc.newTabShortcutURL, text: $shortcutURL)
                .textFieldStyle(.roundedBorder)
            if let shortcutError {
                Text(shortcutError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(loc.cancel) { addingShortcut = false }
                Button(loc.add, action: addShortcut)
                    .keyboardShortcut(.defaultAction)
                    .disabled(shortcutURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear { shortcutError = nil }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSearch(trimmed)
    }

    private func reveal() {
        if reduceMotion {
            appeared = true
        } else {
            withAnimation(Motion.dropdownOpen) { appeared = true }
        }
        DispatchQueue.main.async { searchFocused = true }
    }

    private func addShortcut() {
        var raw = shortcutURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") { raw = "https://\(raw)" }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            shortcutError = loc.newTabShortcutURL
            return
        }
        let title = shortcutTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bookmarks.add(
            title: title.isEmpty ? (url.displayHost ?? raw) : title,
            urlString: url.absoluteString,
            toFolder: selectedFolderID
        ) else {
            shortcutError = loc.alreadyBookmarked
            return
        }
        shortcutTitle = ""
        shortcutURL = ""
        shortcutError = nil
        addingShortcut = false
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString), url.scheme != nil else { return }
        onOpen(url)
    }

    private static func folder(id: UUID, in nodes: [BookmarkNode]) -> BookmarkNode? {
        for node in nodes {
            if node.id == id, node.isFolder { return node }
            if let found = folder(id: id, in: node.children ?? []) { return found }
        }
        return nil
    }
}

private struct NewTabScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
