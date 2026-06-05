import XCTest
import AppKit
@testable import Peekr

/// Pure size-resolution core for per-app panel size memory: precedence is
/// per-app → global default → screen-ratio default, clamped to [minSize, visible].
final class PanelSizeResolutionTests: XCTestCase {
    private let visible = NSSize(width: 1440, height: 900)

    func testPrefersPerAppSize() {
        let s = PanelGeometry.resolveSize(
            app: NSSize(width: 700, height: 500),
            global: NSSize(width: 1000, height: 800),
            visible: visible)
        XCTAssertEqual(s.width, 700)
        XCTAssertEqual(s.height, 500)
    }

    func testFallsBackToGlobalWhenAppIsZero() {
        let s = PanelGeometry.resolveSize(
            app: .zero,
            global: NSSize(width: 1000, height: 800),
            visible: visible)
        XCTAssertEqual(s.width, 1000)
        XCTAssertEqual(s.height, 800)
    }

    func testFallsBackToRatioDefaultWhenAllZero() {
        let s = PanelGeometry.resolveSize(app: .zero, global: .zero, visible: visible)
        let def = PanelGeometry.defaultSize(forVisible: visible)
        XCTAssertEqual(s.width, def.width, accuracy: 0.5)
        XCTAssertEqual(s.height, def.height, accuracy: 0.5)
    }

    func testClampsDownToVisible() {
        let s = PanelGeometry.resolveSize(
            app: NSSize(width: 5000, height: 5000), global: .zero, visible: visible)
        XCTAssertEqual(s.width, visible.width)
        XCTAssertEqual(s.height, visible.height)
    }

    func testClampsUpToMinSize() {
        let s = PanelGeometry.resolveSize(
            app: NSSize(width: 50, height: 50), global: .zero, visible: visible)
        XCTAssertEqual(s.width, PanelGeometry.minSize.width)
        XCTAssertEqual(s.height, PanelGeometry.minSize.height)
    }

    /// Each axis resolves independently: a remembered width with no remembered
    /// height should take the height from the next source in the chain.
    func testPerAxisIndependence() {
        let s = PanelGeometry.resolveSize(
            app: NSSize(width: 640, height: 0),
            global: NSSize(width: 1000, height: 820),
            visible: visible)
        XCTAssertEqual(s.width, 640)
        XCTAssertEqual(s.height, 820)
    }

    func testDefaultSizeKeepsTheTwoThirdsRatio() {
        let def = PanelGeometry.defaultSize(forVisible: visible)
        XCTAssertEqual(def.width, visible.width * (2.0 / 3.0), accuracy: 0.5)
        XCTAssertEqual(def.height, visible.height * 0.92, accuracy: 0.5)
    }
}
