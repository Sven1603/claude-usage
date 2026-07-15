import XCTest
@testable import ClaudeUsageCore

final class SeverityTests: XCTestCase {
    func test_severityBoundaries() {
        XCTAssertEqual(severity(forPercent: 0), .safe)
        XCTAssertEqual(severity(forPercent: 74), .safe)
        XCTAssertEqual(severity(forPercent: 75), .warning)
        XCTAssertEqual(severity(forPercent: 89), .warning)
        XCTAssertEqual(severity(forPercent: 90), .critical)
        XCTAssertEqual(severity(forPercent: 100), .critical)
    }
    func test_windowSeconds() {
        XCTAssertEqual(windowSeconds(forKind: "session"), 5 * 3600)
        XCTAssertEqual(windowSeconds(forKind: "weekly_all"), 7 * 24 * 3600)
        XCTAssertEqual(windowSeconds(forKind: "weekly_scoped"), 7 * 24 * 3600)
    }
    func test_isOverPace() {
        let w = 5 * 3600
        // First 5% of window: never flags, even at high %.
        XCTAssertFalse(isOverPace(percent: 50, secondsToReset: w - 100, windowSeconds: w))
        // Halfway through window (elapsed ~50%): 80% used is ahead of pace → flame.
        XCTAssertTrue(isOverPace(percent: 80, secondsToReset: w / 2, windowSeconds: w))
        // Halfway through, 40% used is behind pace → no flame.
        XCTAssertFalse(isOverPace(percent: 40, secondsToReset: w / 2, windowSeconds: w))
        // Degenerate window.
        XCTAssertFalse(isOverPace(percent: 99, secondsToReset: 0, windowSeconds: 0))
    }
}
