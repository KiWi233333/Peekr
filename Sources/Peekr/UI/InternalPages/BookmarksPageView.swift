import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native `peekr://bookmarks` manager: a folder sidebar beside a bookmark list,
/// with create, rename, edit, move, delete, import and HTML export actions.
struct BookmarksPageView: View {
    let bookmarks: BookmarksModel
    let settings: Settings
    let icons: IconStore
    let currentPage: (title: String, url: URL)?
    let onOpen: (URL) -> Void

    @State private var searchText = ""
    @State private var selectedFolderID: UUID?
    @State private var editingBookmark: BookmarkNode?
    @State private var renamingFolder: BookmarkNode?
    @State private var renameDraft = ""
    @State private var folderPendingDeletion: BookmarkNode?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var importNotice: ImportNotice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loc: Localized { settings.strings }

    private enum Layout {
        static let horizontalPadding: CGFloat = 18
        static let topPadding: CGFloat = 14
        static let compactThreshold: CGFloat = 560
        static let sidebarWidth: CGFloat = min(max(Theme.sidebarWidth, 180), 220)
        static let searchHeight: CGFloat = 30
        static let rowSpacing: CGFloat = 1
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            pageColumn(compact: false)
                .frame(minWidth: Layout.compactThreshold)
            pageColumn(compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { cardSurface }
        .clipShape(cardShape)
        .overlay { cardShape.strokeBorder(Theme.hairline, lineWidth: 1) }
        .alert(importNotice?.title(loc) ?? loc.importBookmarks, isPresented: importNoticeBinding) {
            Button(loc.done, role: .cancel) { importNotice = nil }
        } message: {
            if let importNotice { Text(importNotice.message(loc)) }
        }
        .alert(loc.newFolder, isPresented: $showingNewFolder) {
            TextField(loc.folderName, text: $newFolderName)
            Button(loc.cancel, role: .cancel) { newFolderName = "" }
            Button(loc.add) { createFolder() }
                .disabled(trimmedNewFolderName.isEmpty)
        }
        .alert(loc.rename, isPresented: renameBinding) {
            TextField(loc.folderName, text: $renameDraft)
            Button(loc.cancel, role: .cancel) { renamingFolder = nil }
            Button(loc.save) { commitRename() }
                .disabled(trimmedRenameDraft.isEmpty)
        }
        .alert(loc.deleteFolderTitle, isPresented: deletionBinding) {
            Button(loc.cancel, role: .cancel) { folderPendingDeletion = nil }
            Button(loc.delete, role: .destructive) { deleteFolder() }
        } message: {
            if let folder = folderPendingDeletion {
                Text(
                    loc.deleteFolderMessage(
                        displayTitle(folder),
                        count: linkCount(in: folder.children ?? [])
                    )
                )
            }
        }
        .sheet(item: $editingBookmark) { node in
            BookmarkEditSheet(
                node: node,
                parentFolderID: parentFolderID(of: node.id),
                folders: folderOptions(excluding: nil),
                settings: settings,
                onSave: { title, address, folderID in
                    saveEdit(node, title: title, address: address, folderID: folderID)
                },
                onCancel: { editingBookmark = nil }
            )
        }
        .onChange(of: bookmarks.roots) { _, _ in validateSelection() }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
    }

    private var cardSurface: some View {
        cardShape.fill(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func pageColumn(compact: Bool) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.top, Layout.topPadding)
                .padding(.bottom, 8)

            searchField
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.bottom, 10)

            hairline

            if compact {
                compactFolderBar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                hairline
            }

            HStack(spacing: 0) {
                if !compact {
                    sidebar
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 1)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(loc.bookmarksManager)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                toolbarButton(symbol: "folder.badge.plus", label: loc.newFolder) {
                    beginNewFolder()
                }

                toolbarButton(
                    symbol: "bookmark",
                    label: addCurrentPageLabel,
                    disabled: !canAddCurrentPage
                ) {
                    addCurrentPage()
                }

                importMenu

                toolbarButton(symbol: "square.and.arrow.up", label: loc.exportBookmarks) {
                    exportBookmarks()
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(loc.searchBookmarks, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel(loc.searchBookmarks)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(loc.bookmarksPageClearSearch)
                .accessibilityLabel(loc.bookmarksPageClearSearch)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.searchHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: searchText.isEmpty)
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                FolderSidebarRow(
                    title: loc.allBookmarks,
                    symbol: "bookmark",
                    depth: 0,
                    isSelected: selectedFolderID == nil,
                    action: { selectFolder(nil) }
                )

                ForEach(folderTreeRows) { row in
                    FolderSidebarRow(
                        title: row.title,
                        symbol: "folder",
                        depth: row.depth,
                        isSelected: selectedFolderID == row.id,
                        action: { selectFolder(row.id) }
                    )
                    .contextMenu { folderContextMenu(row.node) }
                }
            }
            .padding(6)
        }
        .frame(width: Layout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.accent.opacity(0.03))
    }

    private var compactFolderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Picker(loc.folder, selection: folderSelection) {
                Text(loc.allBookmarks).tag(UUID?.none)
                ForEach(folderTreeRows) { row in
                    Text(row.menuTitle).tag(Optional(row.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(loc.folder)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !trimmedQuery.isEmpty {
            if searchResults.isEmpty {
                statusState(symbol: "magnifyingglass", title: loc.noMatchingBookmarks)
            } else {
                searchResultsList
            }
        } else if let folder = selectedFolder {
            folderContent(folder)
        } else if bookmarks.allBookmarks().isEmpty {
            statusState(symbol: "bookmark", title: loc.bookmarksEmpty, showsImport: true)
        } else {
            allBookmarksList
        }
    }

    private var allBookmarksList: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: 0,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(bookmarkGroups) { group in
                    Section {
                        ForEach(group.nodes) { node in
                            bookmarkRow(node)
                        }
                    } header: {
                        groupHeader(group.title)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                ForEach(searchResults) { node in
                    bookmarkRow(node)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func folderContent(_ folder: BookmarkNode) -> some View {
        let children = folder.children ?? []
        if children.isEmpty {
            statusState(symbol: "folder", title: loc.emptyFolder)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(children) { node in
                        if node.isFolder {
                            FolderContentRow(title: displayTitle(node)) {
                                selectFolder(node.id)
                            }
                            .contextMenu { folderContextMenu(node) }
                        } else {
                            bookmarkRow(node)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private func bookmarkRow(_ node: BookmarkNode) -> some View {
        BookmarkRow(node: node, icons: icons) {
            open(node)
        }
        .contextMenu { bookmarkContextMenu(node) }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityAddTraits(.isHeader)
    }

    private func statusState(
        symbol: String,
        title: String,
        showsImport: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if showsImport, !sources.isEmpty {
                emptyImportMenu
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbarButton(
        symbol: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(label)
        .accessibilityLabel(label)
    }

    private var importMenu: some View {
        Menu {
            importSourceButtons
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(IconButtonStyle())
        .fixedSize()
        .foregroundStyle(.primary)
        .disabled(sources.isEmpty)
        .opacity(sources.isEmpty ? 0.4 : 1)
        .help(sources.isEmpty ? loc.importNoBrowsers : loc.importBookmarks)
        .accessibilityLabel(loc.importBookmarks)
    }

    private var emptyImportMenu: some View {
        Menu {
            importSourceButtons
        } label: {
            Label(loc.importBookmarks, systemImage: "square.and.arrow.down")
                .font(.system(size: 12, weight: .medium))
        }
        .fixedSize()
    }

    @ViewBuilder
    private var importSourceButtons: some View {
        ForEach(sources, id: \.fileURL) { source in
            Button(source.name) { importSource(source) }
        }
    }

    private var sources: [BookmarkImporter.Source] {
        BookmarkImporter.availableSources()
    }

    private var folderSelection: Binding<UUID?> {
        Binding(get: { selectedFolderID }, set: { selectFolder($0) })
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [BookmarkNode] {
        bookmarks.search(trimmedQuery)
    }

    private var selectedFolder: BookmarkNode? {
        guard let selectedFolderID else { return nil }
        return Self.folder(id: selectedFolderID, in: bookmarks.roots)
    }

    private var folderTreeRows: [FolderRow] {
        var rows: [FolderRow] = []
        appendFolderRows(bookmarks.roots, depth: 0, into: &rows)
        return rows
    }

    private var bookmarkGroups: [BookmarkGroup] {
        var groups: [BookmarkGroup] = []
        let rootLinks = bookmarks.roots.filter { !$0.isFolder }
        if !rootLinks.isEmpty {
            groups.append(BookmarkGroup(id: "root", title: loc.topLevel, nodes: rootLinks))
        }
        appendBookmarkGroups(bookmarks.roots, path: [], into: &groups)
        return groups
    }

    private var canAddCurrentPage: Bool {
        guard let currentPage else { return false }
        return !bookmarks.contains(urlString: currentPage.url.absoluteString)
    }

    private var addCurrentPageLabel: String {
        guard currentPage != nil else { return loc.addCurrentPage }
        return canAddCurrentPage ? loc.addCurrentPage : loc.alreadyBookmarked
    }

    private var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRenameDraft: String {
        renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var importNoticeBinding: Binding<Bool> {
        Binding(
            get: { importNotice != nil },
            set: { if !$0 { importNotice = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }

    private func appendFolderRows(
        _ nodes: [BookmarkNode],
        depth: Int,
        into rows: inout [FolderRow]
    ) {
        for node in nodes where node.isFolder {
            rows.append(FolderRow(node: node, title: displayTitle(node), depth: depth))
            appendFolderRows(node.children ?? [], depth: depth + 1, into: &rows)
        }
    }

    private func appendBookmarkGroups(
        _ nodes: [BookmarkNode],
        path: [String],
        into groups: inout [BookmarkGroup]
    ) {
        for node in nodes where node.isFolder {
            let folderPath = path + [displayTitle(node)]
            let links = (node.children ?? []).filter { !$0.isFolder }
            if !links.isEmpty {
                groups.append(
                    BookmarkGroup(
                        id: node.id.uuidString,
                        title: folderPath.joined(separator: " › "),
                        nodes: links
                    )
                )
            }
            appendBookmarkGroups(node.children ?? [], path: folderPath, into: &groups)
        }
    }

    private func folderOptions(excluding excludedID: UUID?) -> [FolderOption] {
        var options: [FolderOption] = []
        appendFolderOptions(
            bookmarks.roots,
            depth: 0,
            excluding: excludedID,
            into: &options
        )
        return options
    }

    private func appendFolderOptions(
        _ nodes: [BookmarkNode],
        depth: Int,
        excluding excludedID: UUID?,
        into options: inout [FolderOption]
    ) {
        for node in nodes where node.isFolder {
            if node.id == excludedID { continue }
            options.append(
                FolderOption(id: node.id, title: displayTitle(node), depth: depth)
            )
            appendFolderOptions(
                node.children ?? [],
                depth: depth + 1,
                excluding: excludedID,
                into: &options
            )
        }
    }

    private func linkCount(in nodes: [BookmarkNode]) -> Int {
        nodes.reduce(0) { count, node in
            let links = (node.urlString?.isEmpty == false) ? 1 : 0
            return count + links + linkCount(in: node.children ?? [])
        }
    }

    private func displayTitle(_ node: BookmarkNode) -> String {
        let trimmed = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? loc.folder : trimmed
    }

    private func selectFolder(_ id: UUID?) {
        withAnimation(reduceMotion ? nil : Motion.sidebarStyle) {
            selectedFolderID = id
            if !searchText.isEmpty { searchText = "" }
        }
    }

    private func validateSelection() {
        guard let selectedFolderID else { return }
        if Self.folder(id: selectedFolderID, in: bookmarks.roots) == nil {
            self.selectedFolderID = nil
        }
    }

    private func beginNewFolder() {
        newFolderName = ""
        showingNewFolder = true
    }

    private func createFolder() {
        let name = trimmedNewFolderName
        guard !name.isEmpty else { return }
        if let id = bookmarks.createFolder(name: name, in: selectedFolderID) {
            selectFolder(id)
        }
        newFolderName = ""
    }

    private func beginRename(_ node: BookmarkNode) {
        renameDraft = node.title
        renamingFolder = node
    }

    private func commitRename() {
        guard let folder = renamingFolder else { return }
        let name = trimmedRenameDraft
        if !name.isEmpty {
            bookmarks.update(id: folder.id, title: name, urlString: nil)
        }
        renamingFolder = nil
    }

    private func deleteFolder() {
        guard let folder = folderPendingDeletion else { return }
        bookmarks.remove(folder.id)
        folderPendingDeletion = nil
        validateSelection()
    }

    private func move(_ node: BookmarkNode, to folderID: UUID?) {
        guard parentFolderID(of: node.id) != folderID else { return }
        bookmarks.move(id: node.id, toFolder: folderID, at: nil)
    }

    private func open(_ node: BookmarkNode) {
        guard let url = node.urlString.flatMap({ URL(string: $0) }) else { return }
        onOpen(url)
    }

    private func addCurrentPage() {
        guard let currentPage else { return }
        let trimmedTitle = currentPage.title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.add(
            title: trimmedTitle.isEmpty ? currentPage.url.absoluteString : trimmedTitle,
            urlString: currentPage.url.absoluteString,
            toFolder: selectedFolderID
        )
    }

    private func saveEdit(
        _ node: BookmarkNode,
        title: String,
        address: String,
        folderID: UUID?
    ) {
        let previousParent = parentFolderID(of: node.id)
        bookmarks.update(id: node.id, title: title, urlString: address)
        if folderID != previousParent {
            bookmarks.move(id: node.id, toFolder: folderID, at: nil)
        }
        editingBookmark = nil
    }

    private func importSource(_ source: BookmarkImporter.Source) {
        let nodes = BookmarkImporter.importBookmarks(from: source)
        guard !nodes.isEmpty else {
            importNotice = BookmarkImporter.accessDenied(for: source)
                ? .accessDenied
                : .empty(source.name)
            return
        }
        bookmarks.importOrRefreshNodes(nodes, as: source.name)
        if let imported = bookmarks.roots.first(where: {
            $0.isFolder && $0.title == source.name
        }) {
            selectFolder(imported.id)
        }
    }

    private func exportBookmarks() {
        let panel = NSSavePanel()
        panel.title = loc.exportBookmarks
        panel.nameFieldStringValue = "Bookmarks.html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let html = bookmarks.exportHTML()
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func parentFolderID(of id: UUID) -> UUID? {
        Self.parentFolderID(of: id, in: bookmarks.roots, parent: nil)
    }

    @ViewBuilder
    private func bookmarkContextMenu(_ node: BookmarkNode) -> some View {
        if let url = node.urlString.flatMap({ URL(string: $0) }) {
            Button {
                onOpen(url)
            } label: {
                Label(loc.open, systemImage: "arrow.up.right.square")
            }
            Divider()
        }

        Button {
            editingBookmark = node
        } label: {
            Label(loc.edit, systemImage: "pencil")
        }

        moveToFolderMenu(for: node)

        Divider()

        Button(role: .destructive) {
            bookmarks.remove(node.id)
        } label: {
            Label(loc.delete, systemImage: "trash")
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ node: BookmarkNode) -> some View {
        Button {
            beginRename(node)
        } label: {
            Label(loc.rename, systemImage: "pencil")
        }

        moveToFolderMenu(for: node)

        Divider()

        Button(role: .destructive) {
            folderPendingDeletion = node
        } label: {
            Label(loc.delete, systemImage: "trash")
        }
    }

    private func moveToFolderMenu(for node: BookmarkNode) -> some View {
        let options = folderOptions(excluding: node.id)
        return Menu {
            Button(loc.topLevel) { move(node, to: nil) }
            if !options.isEmpty {
                Divider()
                ForEach(options) { option in
                    Button(option.menuTitle) { move(node, to: option.id) }
                }
            }
        } label: {
            Label(loc.moveToFolder, systemImage: "folder")
        }
    }

    private static func folder(id: UUID, in nodes: [BookmarkNode]) -> BookmarkNode? {
        for node in nodes {
            if node.id == id, node.isFolder { return node }
            if let children = node.children,
               let found = folder(id: id, in: children) {
                return found
            }
        }
        return nil
    }

    private static func parentFolderID(
        of id: UUID,
        in nodes: [BookmarkNode],
        parent: UUID?
    ) -> UUID? {
        for node in nodes {
            if node.id == id { return parent }
            if let children = node.children,
               let found = parentFolderID(of: id, in: children, parent: node.id) {
                return found
            }
        }
        return nil
    }
}

private struct FolderRow: Identifiable {
    let node: BookmarkNode
    let title: String
    let depth: Int

    var id: UUID { node.id }

    var menuTitle: String {
        String(repeating: "  ", count: depth) + title
    }
}

private struct FolderOption: Identifiable {
    let id: UUID
    let title: String
    let depth: Int

    var menuTitle: String {
        String(repeating: "  ", count: depth) + title
    }
}

private struct BookmarkGroup: Identifiable {
    let id: String
    let title: String
    let nodes: [BookmarkNode]
}

private enum ImportNotice {
    case accessDenied
    case empty(String)

    func title(_ loc: Localized) -> String {
        switch self {
        case .accessDenied: return loc.importAccessDeniedTitle
        case .empty: return loc.importNoBookmarksTitle
        }
    }

    func message(_ loc: Localized) -> String {
        switch self {
        case .accessDenied: return loc.importAccessDeniedMessage
        case .empty(let browser): return loc.importBookmarksEmpty(browser)
        }
    }
}

private struct FolderSidebarRow: View {
    let title: String
    let symbol: String
    let depth: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.leading, 8 + CGFloat(depth) * 14)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                    .fill(
                        Theme.accent.opacity(
                            isSelected ? 0.10 : (hovering ? 0.05 : 0)
                        )
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FolderContentRow: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.06 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .accessibilityLabel(title)
    }
}

private struct BookmarkRow: View {
    let node: BookmarkNode
    let icons: IconStore
    let onOpen: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var url: URL? {
        node.urlString.flatMap { URL(string: $0) }
    }

    private var iconHost: String? {
        url?.displayHost
    }

    private var title: String {
        let trimmed = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hostSubtitle }
        return trimmed
    }

    private var hostSubtitle: String {
        iconHost ?? url?.scheme ?? node.urlString ?? ""
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                favicon

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !hostSubtitle.isEmpty {
                        Text(hostSubtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.06 : 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .help(node.urlString ?? title)
        .accessibilityLabel(
            hostSubtitle.isEmpty ? title : "\(title), \(hostSubtitle)"
        )
        .task(id: iconHost) {
            guard let iconHost else { return }
            icons.load(host: iconHost)
        }
    }

    private var favicon: some View {
        Group {
            if let iconHost, let image = icons.image(forHost: iconHost) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct BookmarkEditSheet: View {
    let folders: [FolderOption]
    let settings: Settings
    let onSave: (String, String, UUID?) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var address: String
    @State private var folderID: UUID?

    private var loc: Localized { settings.strings }

    init(
        node: BookmarkNode,
        parentFolderID: UUID?,
        folders: [FolderOption],
        settings: Settings,
        onSave: @escaping (String, String, UUID?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.folders = folders
        self.settings = settings
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: node.title)
        _address = State(initialValue: node.urlString ?? "")
        _folderID = State(initialValue: parentFolderID)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedAddress.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.editBookmark)
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            field(loc.title, text: $title, prompt: loc.title)
            field(loc.address, text: $address, prompt: "https://example.com")

            VStack(alignment: .leading, spacing: 4) {
                Text(loc.folder)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker(loc.folder, selection: $folderID) {
                    Text(loc.topLevel).tag(UUID?.none)
                    ForEach(folders) { option in
                        Text(option.menuTitle).tag(Optional(option.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(loc.folder)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(loc.cancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(loc.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .foregroundStyle(.background)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
        }
    }

    private func save() {
        let address = trimmedAddress
        guard !address.isEmpty else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmedTitle.isEmpty ? address : trimmedTitle, address, folderID)
    }
}

/// Keys this page needs that are not yet in `Localized`. Move these into
/// `Localization.swift` and delete this extension when the shell wave lands.
