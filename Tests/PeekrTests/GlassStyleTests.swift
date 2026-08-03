import AppKit
import XCTest
@testable import Peekr

@MainActor
final class GlassStyleTests: XCTestCase {
    func testPanelGlassOwnsHostedContent() throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 640))
        let surface = makePanelBackdrop(contentView: content, cornerRadius: 18)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = try XCTUnwrap(surface as? NSGlassEffectView)
            XCTAssertTrue(glass.contentView === content)
            return
        }
        #endif

        let effect = try XCTUnwrap(surface as? NSVisualEffectView)
        XCTAssertTrue(content.superview === effect)
        XCTAssertEqual(effect.material, .sidebar)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
    }
}
