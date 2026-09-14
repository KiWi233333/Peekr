import XCTest
@testable import Peekr

final class SidebarResizeTests: XCTestCase {
    func testNearestStageUsesThreeAnchors() {
        XCTAssertEqual(SidebarStage.nearest(to: 64), .iconOnly)
        XCTAssertEqual(SidebarStage.nearest(to: 220), .normal)
        XCTAssertEqual(SidebarStage.nearest(to: 350), .expanded)
    }

    func testElasticWidthKeepsInteriorWidthsExact() {
        XCTAssertEqual(SidebarStage.elasticWidth(260), 260)
    }

    func testElasticWidthAddsRubberBandAtBothEnds() {
        XCTAssertEqual(SidebarStage.elasticWidth(40), 60.16, accuracy: 0.01)
        XCTAssertEqual(SidebarStage.elasticWidth(400), 366.4, accuracy: 0.01)
        XCTAssertEqual(SidebarStage.elasticWidth(-1_000), 46, accuracy: 0.01)
    }
}
