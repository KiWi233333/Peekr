import SwiftUI

struct NewTabDetailContent: View {
    let recent: [HistoryEntry]
    let bookmarkLinks: [BookmarkNode]
    let showRecent: Bool
    let showBookmarks: Bool
    let icons: IconStore
    let loc: Localized
    let onOpen: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                columns
            }
            VStack(spacing: 28) {
                columns
            }
        }
    }

    @ViewBuilder
    private var columns: some View {
        if showRecent, !recent.isEmpty {
            section(title: loc.recentlyVisited) {
                ForEach(recent) { entry in
                    NewTabDetailRow(
                        icons: icons,
                        title: displayTitle(entry),
                        host: host(for: entry.urlString),
                        detail: relativeTime(entry.lastVisited),
                        action: { onOpen(entry.urlString) }
                    )
                    if entry.id != recent.last?.id { rowDivider }
                }
            }
        }
        if showBookmarks, !bookmarkLinks.isEmpty {
            section(title: loc.bookmarks) {
                ForEach(bookmarkLinks) { node in
                    NewTabDetailRow(
                        icons: icons,
                        title: bookmarkTitle(node),
                        host: host(for: node.urlString ?? ""),
                        detail: nil,
                        action: {
                            if let urlString = node.urlString { onOpen(urlString) }
                        }
                    )
                    if node.id != bookmarkLinks.last?.id { rowDivider }
                }
            }
        }
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.72))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(.primary.opacity(0.07))
            .padding(.leading, 43)
    }

    private func displayTitle(_ entry: HistoryEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? host(for: entry.urlString) : title
    }

    private func bookmarkTitle(_ node: BookmarkNode) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? host(for: node.urlString ?? "") : title
    }

    private func host(for urlString: String) -> String {
        URL(string: urlString)?.displayHost ?? urlString
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        formatter.locale = Locale(identifier: loc.isChinese ? "zh_CN" : "en_US")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct NewTabDetailRow: View {
    let icons: IconStore
    let title: String
    let host: String
    let detail: String?
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                NewTabFavicon(icons: icons, host: host, title: title, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.045 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .accessibilityLabel([title, host, detail].compactMap { $0 }.joined(separator: ", "))
        .help(title)
    }
}
