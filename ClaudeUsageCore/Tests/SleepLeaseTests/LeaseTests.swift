import XCTest
@testable import SleepLease

final class LeaseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_startingSetsExpiryAtNowPlusTTL() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertEqual(lease.expiresAt, t0.addingTimeInterval(90))
    }

    func test_notExpiredBeforeDeadline() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertFalse(lease.isExpired(at: t0.addingTimeInterval(89)))
    }

    func test_expiredExactlyAtDeadline() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertTrue(lease.isExpired(at: t0.addingTimeInterval(90)))
    }

    func test_renewalExtendsTheDeadline() {
        let lease = Lease.starting(at: t0, ttl: 90)
        let renewed = lease.renewed(at: t0.addingTimeInterval(15), ttl: 90)
        XCTAssertEqual(renewed.expiresAt, t0.addingTimeInterval(105))
        XCTAssertFalse(renewed.isExpired(at: t0.addingTimeInterval(100)))
    }

    // Renewal always recomputes from `now`, so a clock that jumps backwards
    // shortens the lease rather than extending it indefinitely. Failing safe
    // (sleep comes back sooner) is the correct direction for this feature.
    func test_renewalAfterBackwardsClockJumpShortensRatherThanExtends() {
        let lease = Lease.starting(at: t0, ttl: 90)
        let renewed = lease.renewed(at: t0.addingTimeInterval(-3600), ttl: 90)
        XCTAssertLessThan(renewed.expiresAt, lease.expiresAt)
    }

    func test_secondsRemainingCountsDownAndFloorsAtZero() {
        let lease = Lease.starting(at: t0, ttl: 90)
        XCTAssertEqual(lease.secondsRemaining(at: t0.addingTimeInterval(30)), 60)
        XCTAssertEqual(lease.secondsRemaining(at: t0.addingTimeInterval(500)), 0)
    }
}
