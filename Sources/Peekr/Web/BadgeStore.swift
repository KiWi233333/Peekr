import Foundation
import Observation

/// Observable unread-badge counts, keyed by web-app id and derived from page
/// titles via `BadgeParser`. Mirrors the `IconStore` pattern: because it's
/// `@Observable`, the rail's tiles refresh on their own whenever a tab's count
/// changes — including background tabs the user isn't looking at.
@MainActor
@Observable
final class BadgeStore {
    private(set) var counts: [UUID: Int] = [:]

    func count(for id: UUID) -> Int? { counts[id] }

    /// Recompute a tab's badge from its latest title. Clears the entry when the
    /// title carries no unread count.
    func update(_ id: UUID, fromTitle title: String) {
        let new = BadgeParser.unreadCount(fromTitle: title)
        if counts[id] != new { counts[id] = new }
    }

    func clear(_ id: UUID) { counts[id] = nil }
}
