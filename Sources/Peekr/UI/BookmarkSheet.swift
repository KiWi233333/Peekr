import SwiftUI

/// Bookmark manager: an expandable folder tree (like Chrome's) plus an import
/// menu. Clicking a bookmark opens it in the current tab; folders expand.
struct BookmarkSheet: View {
    let bookmarks: BookmarksModel
    let settings: Settings
    var onOpen: (String) -> Void
    var onClose: () -> Void

    private var loc: Localized { settings.strings }
    private var sources: [BookmarkImporter.Source] { BookmarkImporter.availableSources() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc.bookmarks)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                importMenu
                Button(loc.done) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if bookmarks.isEmpty {
                emptyState
            } else {
                List {
                    OutlineGroup(bookmarks.roots, children: \.children) { node in
                        row(node)
                    }
                }
            }
        }
        .frame(width: 460, height: 520)
    }

    private var importMenu: some View {
        Menu(loc.importBookmarks) {
            ForEach(sources) { source in
                Button(source.name) { importFrom(source) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(sources.isEmpty)
    }

    @ViewBuilder
    private func row(_ node: BookmarkNode) -> some View {
        if let url = node.urlString {
            Button { onOpen(url) } label: {
                Label(node.title.isEmpty ? url : node.title, systemImage: "globe")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .contextMenu { deleteButton(node) }
        } else {
            Label(node.title, systemImage: "folder.fill")
                .contextMenu { deleteButton(node) }
        }
    }

    private func deleteButton(_ node: BookmarkNode) -> some View {
        Button(role: .destructive) { bookmarks.remove(node.id) } label: {
            Label(loc.delete, systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
            Text(loc.bookmarksEmpty)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !sources.isEmpty { importMenu }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func importFrom(_ source: BookmarkImporter.Source) {
        bookmarks.importNodes(BookmarkImporter.importBookmarks(from: source), as: source.name)
    }
}
