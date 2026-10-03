import XCTest
@testable import Peekr

final class ZoomStoreTests: XCTestCase {
    func testPerOriginZoomRoundTripsAndClamps() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-zoom-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var store = ZoomStore(fileURL: fileURL)
        store.set(8, for: "https://example.com")
        store.set(-2, for: "https://other.example")

        var reloaded = ZoomStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.level(for: "https://example.com"), 5)
        XCTAssertEqual(reloaded.level(for: "https://other.example"), -2)

        reloaded.reset(for: "https://example.com")
        XCTAssertEqual(ZoomStore(fileURL: fileURL).level(for: "https://example.com"), 0)
    }
}
