import AppKit
import XCTest
@testable import Peekr

final class PanelResizeGeometryTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let start = NSRect(x: 100, y: 200, width: 800, height: 500)

    func testBottomRightResizeKeepsTopAndLeftFixed() {
        let resized = PanelGeometry.resizedFrame(
            from: start,
            dragging: [.trailing, .bottom],
            delta: NSSize(width: 120, height: -80),
            within: bounds)

        XCTAssertEqual(resized.minX, start.minX)
        XCTAssertEqual(resized.maxY, start.maxY)
        XCTAssertEqual(resized.maxX, start.maxX + 120)
        XCTAssertEqual(resized.minY, start.minY - 80)
    }

    func testTopLeftResizeKeepsBottomAndRightFixed() {
        let resized = PanelGeometry.resizedFrame(
            from: start,
            dragging: [.leading, .top],
            delta: NSSize(width: -60, height: 90),
            within: bounds)

        XCTAssertEqual(resized.maxX, start.maxX)
        XCTAssertEqual(resized.minY, start.minY)
        XCTAssertEqual(resized.minX, start.minX - 60)
        XCTAssertEqual(resized.maxY, start.maxY + 90)
    }

    func testResizeClampsMovingEdgesToVisibleBounds() {
        let resized = PanelGeometry.resizedFrame(
            from: start,
            dragging: [.trailing, .bottom],
            delta: NSSize(width: 10_000, height: -10_000),
            within: bounds)

        XCTAssertEqual(resized.minX, start.minX)
        XCTAssertEqual(resized.maxY, start.maxY)
        XCTAssertEqual(resized.maxX, bounds.maxX)
        XCTAssertEqual(resized.minY, bounds.minY)
    }

    func testResizeStopsAtMinimumWithoutMovingOppositeEdges() {
        let resized = PanelGeometry.resizedFrame(
            from: start,
            dragging: [.leading, .bottom],
            delta: NSSize(width: 10_000, height: 10_000),
            within: bounds)

        XCTAssertEqual(resized.maxX, start.maxX)
        XCTAssertEqual(resized.maxY, start.maxY)
        XCTAssertEqual(resized.width, PanelGeometry.minSize.width)
        XCTAssertEqual(resized.height, PanelGeometry.minSize.height)
    }
}
