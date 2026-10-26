import AppKit
import SwiftUI

/// Native `peekr://history` page: live search, day-grouped visits, per-entry
/// delete and a confirmed clear-all. Self-contained card so the internal-page
/// host can drop it straight into the panel's web area.
struct HistoryPageView: View {
    let history: HistoryStore
    let settings: Settings
    let icons: IconStore
    let onOpen: (URL) -> Void

    @State private var query = ""
    @State private var confirmingClear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loc: Localized { settings.strings }

    private enum Layout {
        static let horizontalPadding: CGFloat = 18
        static let topPadding: CGFloat = 16
        static let bottomPadding: CGFloat = 12
        static let contentMaxWidth: CGFloat = 880
        static let rowSpacing: CGFloat = 2
        static let searchHeight: CGFloat = 30
    }

    private var filteredEntries: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? history.entries : history.search(trimmed)
    }

    private var dayGroups: [HistoryDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredEntries) {
            calendar.startOfDay(for: $0.lastVisited)
        }
        return grouped.keys.sorted(by: >).map { day in
            HistoryDayGroup(
                day: day,
                entries: grouped[day, default: []].sorted { $0.lastVisited > $1.lastVisited }
            )
        }
    }

    var body: some View {
        pageColumn
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, Layout.topPadding)
            .padding(.bottom, Layout.bottomPadding)
            .frame(maxWidth: Layout.contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .confirmationDialog(
                loc.clearHistoryTitle,
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button(loc.clearAll, role: .destructive) { history.removeAll() }
                Button(loc.cancel, role: .cancel) {}
            } message: {
                Text(loc.clearHistoryMessage)
            }
    }

    private var pageColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            searchField
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            content
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(loc.history)
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            Button {
                confirmingClear = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text(loc.clearAll)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                        .fill(.primary.opacity(0.06))
                }
                .contentShape(
                    RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(history.entries.isEmpty)
            .opacity(history.entries.isEmpty ? 0.4 : 1)
            .help(loc.clearAll)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(loc.searchHistory, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel(loc.searchHistory)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(loc.clearSearch)
                .accessibilityLabel(loc.clearSearch)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.searchHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: query.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if history.entries.isEmpty {
            statusState(symbol: "clock", title: loc.noHistory)
        } else if filteredEntries.isEmpty {
            statusState(symbol: "magnifyingglass", title: loc.noMatchingHistory)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.rowSpacing, pinnedViews: [.sectionHeaders]) {
                    ForEach(dayGroups) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                HistoryRow(
                                    entry: entry,
                                    settings: settings,
                                    icons: icons,
                                    onOpen: onOpen,
                                    onRemove: { history.remove(urlString: entry.urlString) }
                                )
                            }
                        } header: {
                            sectionHeader(for: group.day)
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func sectionHeader(for day: Date) -> some View {
        Text(dayTitle(for: day))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityAddTraits(.isHeader)
    }

    private func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return loc.today }
        if calendar.isDateInYesterday(day) { return loc.yesterday }
        return day.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: displayLocale)
        )
    }

    private var displayLocale: Locale {
        Locale(identifier: loc.isChinese ? "zh_CN" : "en_US")
    }

    private func statusState(symbol: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

private struct HistoryDayGroup: Identifiable {
    let day: Date
    let entries: [HistoryEntry]

    var id: Date { day }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let settings: Settings
    let icons: IconStore
    let onOpen: (URL) -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loc: Localized { settings.strings }

    private var url: URL? { URL(string: entry.urlString) }
    private var host: String? { url?.displayHost ?? url?.host }
    private var displayLocale: Locale {
        Locale(identifier: loc.isChinese ? "zh_CN" : "en_US")
    }

    private var title: String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (host ?? entry.urlString) : trimmed
    }

    private var subtitle: String { host ?? entry.urlString }

    private var visitTime: String {
        entry.lastVisited.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: displayLocale)
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    favicon

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        if entry.visitCount > 1 {
                            Text(loc.visitCount(entry.visitCount))
                        }
                        Text(visitTime)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.leading, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(url == nil)

            deleteButton
        }
        .padding(.trailing, 4)
        .background {
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
        )
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .contextMenu {
            Button(loc.delete, role: .destructive, action: onRemove)
        }
        .task(id: host) {
            guard let host else { return }
            icons.load(host: host)
        }
    }

    private var favicon: some View {
        Group {
            if let host, let image = icons.image(forHost: host) {
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

    private var deleteButton: some View {
        Button(action: onRemove) {
            Image(systemName: "trash")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!hovering)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .accessibilityHidden(!hovering)
        .help(loc.delete)
        .accessibilityLabel(loc.delete)
    }

    private func open() {
        guard let url else { return }
        onOpen(url)
    }
}

/// Keys this page needs that are not yet in `Localized`. Move these into
/// `Localization.swift` and delete this extension when the shell wave lands.
