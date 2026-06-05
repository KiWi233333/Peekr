import XCTest
@testable import Peekr

/// `HibernationPolicy` decides which background tabs to fully suspend after an
/// idle threshold — mirroring Chrome/Edge "sleeping tabs": never the active tab,
/// an audible tab, or one the user kept awake. Time is injected so the rule is
/// deterministic without waiting on a real clock.
final class HibernationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let policy = HibernationPolicy(idleThreshold: 600) // 10 minutes

    private func candidate(
        idleFor seconds: TimeInterval,
        isActive: Bool = false,
        keepAwake: Bool = false,
        isAudible: Bool = false,
        isAsleep: Bool = false
    ) -> HibernationCandidate {
        HibernationCandidate(
            id: UUID(),
            lastActiveAt: now.addingTimeInterval(-seconds),
            isActive: isActive,
            keepAwake: keepAwake,
            isAudible: isAudible,
            isAsleep: isAsleep
        )
    }

    func testIdleBeyondThresholdHibernates() {
        let c = candidate(idleFor: 601)
        XCTAssertEqual(policy.tabsToHibernate([c], now: now), [c.id])
    }

    func testRecentlyActiveStaysAwake() {
        let c = candidate(idleFor: 599)
        XCTAssertTrue(policy.tabsToHibernate([c], now: now).isEmpty)
    }

    /// Boundary: idle == threshold is eligible (>=), so the rule is inclusive.
    func testExactlyAtThresholdHibernates() {
        let c = candidate(idleFor: 600)
        XCTAssertEqual(policy.tabsToHibernate([c], now: now), [c.id])
    }

    func testActiveTabNeverHibernates() {
        let c = candidate(idleFor: 10_000, isActive: true)
        XCTAssertTrue(policy.tabsToHibernate([c], now: now).isEmpty)
    }

    func testAudibleTabNeverHibernates() {
        let c = candidate(idleFor: 10_000, isAudible: true)
        XCTAssertTrue(policy.tabsToHibernate([c], now: now).isEmpty)
    }

    func testKeepAwakeTabNeverHibernates() {
        let c = candidate(idleFor: 10_000, keepAwake: true)
        XCTAssertTrue(policy.tabsToHibernate([c], now: now).isEmpty)
    }

    func testAlreadyAsleepTabSkipped() {
        let c = candidate(idleFor: 10_000, isAsleep: true)
        XCTAssertTrue(policy.tabsToHibernate([c], now: now).isEmpty)
    }

    /// A zero threshold means "auto-sleep off" — manual sleep still works, but
    /// the policy never picks anything on its own.
    func testZeroThresholdDisablesAutoHibernate() {
        let disabled = HibernationPolicy(idleThreshold: 0)
        let c = candidate(idleFor: 10_000)
        XCTAssertTrue(disabled.tabsToHibernate([c], now: now).isEmpty)
    }

    func testFiltersMixedSetToOnlyEligible() {
        let sleepy = candidate(idleFor: 700)
        let fresh = candidate(idleFor: 100)
        let active = candidate(idleFor: 700, isActive: true)
        let result = policy.tabsToHibernate([sleepy, fresh, active], now: now)
        XCTAssertEqual(result, [sleepy.id])
    }
}
