import XCTest
@testable import Peekr

final class HistoryStoreTests: XCTestCase {
    func testRecordMovesExistingPageToTheFrontAndPersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var store = HistoryStore(fileURL: url)
        store.record(url: URL(string: "https://one.example")!, title: "One")
        store.record(url: URL(string: "https://two.example")!, title: "Two")
        store.record(url: URL(string: "https://one.example")!, title: "One, updated")

        XCTAssertEqual(store.entries.map(\.urlString), [
            "https://one.example", "https://two.example"
        ])
        XCTAssertEqual(store.entries.first?.title, "One, updated")
        XCTAssertEqual(HistoryStore(fileURL: url).entries, store.entries)
    }

    func testRecordSkipsNonPageSchemes() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var store = HistoryStore(fileURL: url)
        store.record(url: URL(string: "about:blank")!, title: "Blank")
        store.record(url: URL(string: "data:text/plain,hello")!, title: "Data")

        XCTAssertTrue(store.entries.isEmpty)
    }
}
