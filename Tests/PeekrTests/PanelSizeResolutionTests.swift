import XCTest
import AppKit
@testable import Peekr

/// Pure size-resolution core for the single global panel size: precedence is
/// global value → screen-ratio default, clamped to [minSize, visible].
final class PanelSizeResolutionTests: XCTestCase {
    private let visible = NSSize(width: 1440, height: 900)

    func testPrefersGlobalSize() {
        let s = PanelGeometry.resolveSize(
            global: NSSize(width: 1000, height: 800),
            visible: visible)
        XCTAssertEqual(s.width, 1000)
        XCTAssertEqual(s.height, 800)
    }

    func testFallsBackToRatioDefaultWhenGlobalZero() {
        let s = PanelGeometry.resolveSize(global: .zero, visible: visible)
        let def = PanelGeometry.defaultSize(forVisible: visible)
        XCTAssertEqual(s.width, def.width, accuracy: 0.5)
        XCTAssertEqual(s.height, def.height, accuracy: 0.5)
    }

    func testClampsDownToVisible() {
        let s = PanelGeometry.resolveSize(
            global: NSSize(width: 5000, height: 5000), visible: visible)
        XCTAssertEqual(s.width, visible.width)
        XCTAssertEqual(s.height, visible.height)
    }

    func testClampsUpToMinSize() {
        let s = PanelGeometry.resolveSize(
            global: NSSize(width: 50, height: 50), visible: visible)
        XCTAssertEqual(s.width, PanelGeometry.minSize.width)
        XCTAssertEqual(s.height, PanelGeometry.minSize.height)
    }

    /// Each axis resolves independently: a set width with a zero height should
    /// take the height from the screen-ratio default.
    func testPerAxisIndependence() {
        let s = PanelGeometry.resolveSize(
            global: NSSize(width: 640, height: 0),
            visible: visible)
        let def = PanelGeometry.defaultSize(forVisible: visible)
        XCTAssertEqual(s.width, 640)
        XCTAssertEqual(s.height, def.height, accuracy: 0.5)
    }

    func testDefaultSizeKeepsTheTwoThirdsRatio() {
        let def = PanelGeometry.defaultSize(forVisible: visible)
        XCTAssertEqual(def.width, visible.width * (2.0 / 3.0), accuracy: 0.5)
        XCTAssertEqual(def.height, visible.height * 0.92, accuracy: 0.5)
    }
}
