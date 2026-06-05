import XCTest
@testable import Peekr

/// `BadgeStore` turns page titles into per-app counts and drops the entry when a
/// title no longer carries an unread count.
@MainActor
final class BadgeStoreTests: XCTestCase {
    func testUpdateSetsCountFromTitle() {
        let store = BadgeStore()
        let id = UUID()
        store.update(id, fromTitle: "(4) Inbox")
        XCTAssertEqual(store.count(for: id), 4)
    }

    func testUpdateClearsWhenTitleLosesCount() {
        let store = BadgeStore()
        let id = UUID()
        store.update(id, fromTitle: "(4) Inbox")
        store.update(id, fromTitle: "Inbox")
        XCTAssertNil(store.count(for: id))
    }

    func testClearRemovesBadge() {
        let store = BadgeStore()
        let id = UUID()
        store.update(id, fromTitle: "(2) Chat")
        store.clear(id)
        XCTAssertNil(store.count(for: id))
    }
}
