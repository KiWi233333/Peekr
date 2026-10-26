import SwiftUI

/// `peekr://shortcuts` — one place to discover the panel's browser shortcuts.
struct ShortcutsPageView: View {
    let settings: Settings

    private var loc: Localized { settings.strings }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private struct Row: Identifiable {
        let id: String
        let action: String
        let keys: String
    }

    private var sections: [Section] {
        [
            Section(id: "navigation", title: loc.shortcutNavigation, rows: [
                Row(id: "back", action: loc.back, keys: "⌘ ["),
                Row(id: "forward", action: loc.forward, keys: "⌘ ]"),
                Row(id: "reload", action: loc.reload, keys: "⌘ R"),
                Row(id: "hardReload", action: loc.hardReload, keys: "⇧ ⌘ R"),
                Row(id: "focus", action: loc.focusAddressBar, keys: "⌘ L"),
            ]),
            Section(id: "tabs", title: loc.shortcutTabs, rows: [
                Row(id: "newTab", action: loc.newTab, keys: "⌘ T"),
                Row(id: "closeTab", action: loc.closeTab, keys: "⌘ W"),
                Row(id: "reopen", action: loc.reopenClosedTab, keys: "⇧ ⌘ T"),
                Row(id: "next", action: loc.nextTab, keys: "⌃ Tab"),
                Row(id: "previous", action: loc.previousTab, keys: "⌃ ⇧ Tab"),
                Row(id: "select", action: loc.selectTabNumber, keys: "⌘ 1–9"),
                Row(id: "tabSearch", action: loc.tabSearch, keys: "⇧ ⌘ A"),
            ]),
            Section(id: "page", title: loc.shortcutPage, rows: [
                Row(id: "find", action: loc.findInPage, keys: "⌘ F"),
                Row(id: "findNext", action: loc.findNext, keys: "⌘ G"),
                Row(id: "findPrevious", action: loc.findPrevious, keys: "⇧ ⌘ G"),
                Row(id: "zoomIn", action: loc.zoomIn, keys: "⌘ ="),
                Row(id: "zoomOut", action: loc.zoomOut, keys: "⌘ -"),
                Row(id: "zoomReset", action: loc.resetZoom, keys: "⌘ 0"),
                Row(id: "devtools", action: loc.inspect, keys: "⌥ ⌘ I"),
                Row(id: "viewSource", action: loc.viewSource, keys: "⌘ U"),
            ]),
            Section(id: "panels", title: loc.shortcutPanels, rows: [
                Row(id: "history", action: loc.history, keys: "⌘ Y"),
                Row(id: "downloads", action: loc.downloads, keys: "⇧ ⌘ J"),
                Row(id: "bookmarks", action: loc.bookmarksManager, keys: "⇧ ⌘ O"),
                Row(id: "preferences", action: loc.preferences, keys: "⌘ ,"),
                Row(id: "closePanel", action: loc.hidePeekr, keys: "Esc / ⇧ ⌘ W"),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(loc.shortcuts)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        VStack(spacing: 0) {
                            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                HStack(spacing: 12) {
                                    Text(row.action)
                                        .font(.system(size: 12.5))
                                    Spacer(minLength: 12)
                                    Text(row.keys)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            .primary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        )
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)

                                if index < section.rows.count - 1 {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }
}
