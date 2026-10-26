import Foundation
import Observation

/// One recent page visit used by the omnibox and the history page.
struct HistoryEntry: Codable, Hashable, Identifiable {
    let urlString: String
    var title: String
    var lastVisited: Date
    var visitCount: Int
    var firstVisited: Date

    var id: String { urlString }

    init(
        urlString: String,
        title: String,
        lastVisited: Date,
        visitCount: Int = 1,
        firstVisited: Date? = nil
    ) {
        self.urlString = urlString
        self.title = title
        self.lastVisited = lastVisited
        self.visitCount = visitCount
        self.firstVisited = firstVisited ?? lastVisited
    }

    private enum CodingKeys: String, CodingKey {
        case urlString, title, lastVisited, visitCount, firstVisited
    }

    // v1 files stored only urlString/title/lastVisited; fill the visit fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try c.decode(String.self, forKey: .urlString)
        title = try c.decode(String.self, forKey: .title)
        lastVisited = try c.decode(Date.self, forKey: .lastVisited)
        visitCount = try c.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
        firstVisited = try c.decodeIfPresent(Date.self, forKey: .firstVisited) ?? lastVisited
    }
}

/// Observable recency index for the omnibox, the history page and new-tab top
/// sites. Kept as a compact JSON array rather than a database dependency.
@Observable
final class HistoryStore {
    static let maxEntries = 10_000

    let fileURL: URL
    private(set) var entries: [HistoryEntry]

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("history.json")) {
        self.fileURL = fileURL
        let decoded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
        entries = Array(decoded.sorted { $0.lastVisited > $1.lastVisited }.prefix(Self.maxEntries))
    }

    func record(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return }

        let urlString = url.absoluteString
        let fallbackTitle = url.displayHost ?? urlString
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        if let index = entries.firstIndex(where: { $0.urlString == urlString }) {
            var entry = entries.remove(at: index)
            if !cleanedTitle.isEmpty {
                entry.title = cleanedTitle
            } else if entry.title.isEmpty {
                entry.title = fallbackTitle
            }
            entry.lastVisited = now
            entry.visitCount += 1
            entries.insert(entry, at: 0)
        } else {
            entries.insert(
                HistoryEntry(
                    urlString: urlString,
                    title: cleanedTitle.isEmpty ? fallbackTitle : cleanedTitle,
                    lastVisited: now,
                    visitCount: 1,
                    firstVisited: now
                ),
                at: 0
            )
        }

        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    /// Case-insensitive substring match over title and URL, newest first.
    func search(_ query: String, limit: Int = 100) -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(entries.prefix(limit)) }
        let matches = entries.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.urlString.localizedCaseInsensitiveContains(trimmed)
        }
        return Array(matches.prefix(limit))
    }

    /// Most-visited pages, breaking ties by recency.
    func topSites(limit: Int = 12) -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let ranked = entries.sorted {
            $0.visitCount != $1.visitCount
                ? $0.visitCount > $1.visitCount
                : $0.lastVisited > $1.lastVisited
        }
        return Array(ranked.prefix(limit))
    }

    func remove(urlString: String) {
        let count = entries.count
        entries.removeAll { $0.urlString == urlString }
        if entries.count != count { save() }
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    func prune(olderThan days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let count = entries.count
        entries.removeAll { $0.lastVisited < cutoff }
        if entries.count != count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
