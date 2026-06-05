import XCTest
@testable import Peekr

/// `displayName` is the single source for "what to call this app" — a user alias
/// wins, then the page title, then the host, then the raw URL.
final class WebAppIdentityTests: XCTestCase {
    func testPrefersAlias() {
        var app = WebApp(title: "GitHub", urlString: "https://github.com")
        app.alias = "Work Repo"
        XCTAssertEqual(app.displayName, "Work Repo")
    }

    func testFallsBackToTitle() {
        let app = WebApp(title: "GitHub", urlString: "https://github.com")
        XCTAssertEqual(app.displayName, "GitHub")
    }

    func testFallsBackToHostWhenNoAliasOrTitle() {
        let app = WebApp(title: "", urlString: "https://github.com/foo")
        XCTAssertEqual(app.displayName, "github.com")
    }

    func testFallsBackToURLStringWhenNoHost() {
        let app = WebApp(title: "", urlString: "not a url")
        XCTAssertEqual(app.displayName, "not a url")
    }

    func testIgnoresWhitespaceOnlyAlias() {
        var app = WebApp(title: "GitHub", urlString: "https://github.com")
        app.alias = "   "
        XCTAssertEqual(app.displayName, "GitHub")
    }

    func testAliasRoundTrips() throws {
        var app = WebApp(title: "GitHub", urlString: "https://github.com")
        app.alias = "Work"
        let decoded = try JSONDecoder().decode(WebApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(decoded.alias, "Work")
    }

    func testTolerantDecodeDefaultsAliasToEmpty() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"X","urlString":"https://x.com","usesCustomIcon":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(WebApp.self, from: json)
        XCTAssertEqual(decoded.alias, "")
    }
}
