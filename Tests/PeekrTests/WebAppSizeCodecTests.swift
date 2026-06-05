import XCTest
@testable import Peekr

/// Per-app panel size must survive a JSON round-trip and tolerate older files
/// that predate the fields (the repo's tolerant-decode convention).
final class WebAppSizeCodecTests: XCTestCase {
    func testRoundTripPreservesPerAppSize() throws {
        var app = WebApp(title: "GitHub", urlString: "https://github.com")
        app.panelWidth = 720
        app.panelHeight = 560
        let data = try JSONEncoder().encode(app)
        let decoded = try JSONDecoder().decode(WebApp.self, from: data)
        XCTAssertEqual(decoded.panelWidth, 720)
        XCTAssertEqual(decoded.panelHeight, 560)
    }

    func testTolerantDecodeOfPreSizeJSON() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"Old","urlString":"https://example.com","usesCustomIcon":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(WebApp.self, from: json)
        XCTAssertEqual(decoded.panelWidth, 0)
        XCTAssertEqual(decoded.panelHeight, 0)
        XCTAssertEqual(decoded.title, "Old")
    }
}
