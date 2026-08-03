import XCTest
@testable import Peekr

@MainActor
final class CefConfigurationTests: XCTestCase {
    func testChromiumKeepsItsStandardUserAgentProduct() {
        XCTAssertNil(
            PeekrApp.cefConfiguration.userAgentProduct,
            "Setting userAgentProduct replaces CEF's Chrome/<version> token"
        )
    }
}
