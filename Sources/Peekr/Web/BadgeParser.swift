import Foundation

/// Derives an unread-badge count from a page's title, the way multi-service
/// browsers (Ferdium / Rambox / Franz) do: the first parenthesised integer is
/// the unread count. Most messaging/mail apps surface their unread count in
/// `document.title` — e.g. "(3) WhatsApp", "Inbox (12) - me@gmail.com",
/// "(99+) Messages". `0` and "no number" mean no badge.
///
/// It's a heuristic: a parenthesised year ("(2026) …") can false-positive. That
/// tradeoff is the category norm for title-based badging and keeps it zero-config
/// — no per-site rules to maintain.
enum BadgeParser {
    /// Digits inside parens, optionally followed by a `+` ("99+" → 99).
    private static let pattern = try! NSRegularExpression(pattern: #"\((\d+)\+?\)"#)

    static func unreadCount(fromTitle title: String) -> Int? {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = pattern.firstMatch(in: title, range: range),
              let digits = Range(match.range(at: 1), in: title),
              let count = Int(title[digits]), count > 0
        else { return nil }
        return count
    }
}
