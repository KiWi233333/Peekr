import XCTest
@testable import Peekr

/// Unread badges are derived from the page title the way multi-service browsers
/// (Ferdium / Rambox / Franz) do it: the first parenthesised integer is the
/// unread count. `0` and "no number" mean no badge.
final class BadgeParserTests: XCTestCase {
    func testLeadingParenCount() {
        XCTAssertEqual(BadgeParser.unreadCount(fromTitle: "(3) WhatsApp"), 3)
    }

    func testMidStringParenCount() {
        XCTAssertEqual(BadgeParser.unreadCount(fromTitle: "Inbox (12) - me@gmail.com"), 12)
    }

    func testNoCount() {
        XCTAssertNil(BadgeParser.unreadCount(fromTitle: "WhatsApp"))
    }

    func testZeroIsNoBadge() {
        XCTAssertNil(BadgeParser.unreadCount(fromTitle: "(0) Inbox"))
    }

    func testPlusSuffixCapsAtNumber() {
        XCTAssertEqual(BadgeParser.unreadCount(fromTitle: "(99+) Messages"), 99)
    }

    func testEmptyTitle() {
        XCTAssertNil(BadgeParser.unreadCount(fromTitle: ""))
    }

    func testFirstParenWins() {
        XCTAssertEqual(BadgeParser.unreadCount(fromTitle: "(5) Slack | (9) general"), 5)
    }

    // MARK: - strippingCount (rail title shouldn't duplicate the badge number)

    func testStripLeadingCount() {
        XCTAssertEqual(BadgeParser.strippingCount(fromTitle: "(3) WhatsApp"), "WhatsApp")
    }

    func testStripMidStringCountTidiesSeparator() {
        XCTAssertEqual(BadgeParser.strippingCount(fromTitle: "Inbox (12) - me@gmail.com"),
                       "Inbox - me@gmail.com")
    }

    func testStripPlusSuffixCount() {
        XCTAssertEqual(BadgeParser.strippingCount(fromTitle: "(99+) Messages"), "Messages")
    }

    func testStripPreservesNameWithPipe() {
        XCTAssertEqual(BadgeParser.strippingCount(fromTitle: "(3) JiwuChat | 极物聊天"),
                       "JiwuChat | 极物聊天")
    }

    func testNoCountLeavesTitleUntouched() {
        XCTAssertEqual(BadgeParser.strippingCount(fromTitle: "WhatsApp"), "WhatsApp")
    }

    func testCountOnlyTitleStripsToEmpty() {
        XCTAssertEqual(BadgeParser.strippingCount(fromTitle: "(7)"), "")
    }
}
