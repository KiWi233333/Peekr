import XCTest
@testable import Peekr

/// The web-engine preference must survive a JSON round-trip and default to
/// `.system` for files written before the field existed (tolerant-decode
/// convention), so adding it never discards a user's settings.json.
final class SettingsEngineCodecTests: XCTestCase {
    func testRoundTripPreservesWebEngine() throws {
        var data = SettingsData()
        data.webEngine = .chromium
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: encoded)
        XCTAssertEqual(decoded.webEngine, .chromium)
    }

    func testTolerantDecodeDefaultsEngineToSystem() throws {
        // A settings file from before the webEngine field shipped.
        let json = Data(#"{"anchor":"right","autoHide":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: json)
        XCTAssertEqual(decoded.webEngine, .system)
    }

    func testChromiumIsNotAvailableYet() {
        XCTAssertFalse(WebEngineKind.chromium.isAvailable)
        XCTAssertTrue(WebEngineKind.system.isAvailable)
    }

    /// Until the CEF backend ships, every kind must resolve to the WebKit factory
    /// — the setting only records intent. This locks that contract so a future
    /// edit can't silently route `.chromium` to a half-built engine.
    @MainActor
    func testEveryKindFallsBackToWebKitFactory() {
        for kind in WebEngineKind.allCases {
            XCTAssertTrue(kind.makeFactory() is WebKitEngineFactory,
                          "\(kind) should resolve to WebKitEngineFactory until CEF ships")
        }
    }
}
