import Foundation

/// One recent page visit used by the omnibox. Peekr keeps a compact recency
/// index rather than a full Chrome-style history database; this is enough to
/// make frequently visited pages discoverable without adding a new database
/// dependency to the slide-over browser.
struct HistoryEntry: Codable, Hashable, Identifiable {
    let urlString: String
    var title: String
    var lastVisited: Date

    var id: String { urlString }
}

struct HistoryStore {
    static let maxEntries = 200

    let fileURL: URL
    private(set) var entries: [HistoryEntry]

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("history.json")) {
        self.fileURL = fileURL
        entries = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
        entries.sort { $0.lastVisited > $1.lastVisited }
        entries = Array(entries.prefix(Self.maxEntries))
    }

    mutating func record(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return }

        let urlString = url.absoluteString
        let fallbackTitle = url.displayHost ?? urlString
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { $0.urlString == urlString }
        entries.insert(
            HistoryEntry(
                urlString: urlString,
                title: cleanedTitle.isEmpty ? fallbackTitle : cleanedTitle,
                lastVisited: Date()
            ),
            at: 0
        )
        entries = Array(entries.prefix(Self.maxEntries))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
