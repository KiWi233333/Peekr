import AppKit
import XCTest
@testable import Peekr

@MainActor
final class GlassStyleTests: XCTestCase {
    func testPanelSurfaceOwnsHostedContent() throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 640))
        let surface = makePanelBackdrop(contentView: content, cornerRadius: 18)

        XCTAssertTrue(surface === content)
        XCTAssertEqual(content.layer?.cornerRadius, 18)
        XCTAssertTrue(content.layer?.masksToBounds == true)
    }
}
