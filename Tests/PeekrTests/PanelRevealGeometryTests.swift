import AppKit
import XCTest
@testable import Peekr

final class PanelRevealGeometryTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 24, width: 1_440, height: 852)
    private let full = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let size = NSSize(width: 720, height: 640)

    func testSideAnchorsSlideAlongTheirDockedEdge() {
        let left = layout(.left)
        XCTAssertEqual(left.offscreen.origin, NSPoint(x: full.minX - size.width, y: left.onscreen.minY))

        let right = layout(.right)
        XCTAssertEqual(right.offscreen.origin, NSPoint(x: full.maxX, y: right.onscreen.minY))
    }

    func testCornerAnchorsSlideFromAndBackToTheirCorner() {
        let expected: [(PanelAnchor, NSPoint)] = [
            (.topLeft, NSPoint(x: full.minX - size.width, y: full.maxY)),
            (.topRight, NSPoint(x: full.maxX, y: full.maxY)),
            (.bottomLeft, NSPoint(x: full.minX - size.width, y: full.minY - size.height)),
            (.bottomRight, NSPoint(x: full.maxX, y: full.minY - size.height))
        ]

        for (anchor, origin) in expected {
            let frames = layout(anchor)
            XCTAssertEqual(frames.offscreen.origin, origin, "Unexpected reveal origin for \(anchor)")
            XCTAssertEqual(frames.offscreen.size, frames.onscreen.size)
        }
    }

    private func layout(_ anchor: PanelAnchor) -> PanelLayout {
        PanelGeometry.layout(
            anchor: anchor,
            visibleFrame: visible,
            screenFrame: full,
            size: size
        )
    }
}
