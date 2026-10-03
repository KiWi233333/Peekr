import XCTest
@testable import Peekr

@MainActor
final class DownloadStoreTests: XCTestCase {
    func testProgressIsClampedAndUnknownLengthHasNoProgress() {
        let known = WebDownload(
            id: 1,
            url: URL(string: "https://example.com/file.zip"),
            fileName: "file.zip",
            receivedBytes: 150,
            totalBytes: 100,
            state: .downloading,
            location: nil
        )
        let unknown = WebDownload(
            id: 2,
            url: nil,
            fileName: "stream.bin",
            receivedBytes: 50,
            totalBytes: 0,
            state: .downloading,
            location: nil
        )

        XCTAssertEqual(known.progress, 1)
        XCTAssertNil(unknown.progress)
    }

    func testUpdatesReplaceByIDAndClearFinishedKeepsActive() {
        let store = DownloadStore()
        store.update(WebDownload(
            id: 7,
            url: URL(string: "https://example.com/file.txt"),
            fileName: "file.txt",
            receivedBytes: 10,
            totalBytes: 100,
            state: .downloading,
            location: nil
        ))
        store.update(WebDownload(
            id: 7,
            url: URL(string: "https://example.com/file.txt"),
            fileName: "file.txt",
            receivedBytes: 100,
            totalBytes: 100,
            state: .completed,
            location: URL(fileURLWithPath: "/tmp/file.txt")
        ))
        store.update(WebDownload(
            id: 8,
            url: nil,
            fileName: "live.bin",
            receivedBytes: 1,
            totalBytes: 0,
            state: .downloading,
            location: nil
        ))

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records.first(where: { $0.id == 7 })?.state, .completed)
        XCTAssertEqual(store.activeCount, 1)

        store.clearFinished()

        XCTAssertEqual(store.records.map(\.id), [8])
        XCTAssertEqual(store.activeCount, 1)
    }
}
