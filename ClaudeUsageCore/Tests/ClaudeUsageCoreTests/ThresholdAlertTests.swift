import XCTest
@testable import ClaudeUsageCore

final class ThresholdAlertTests: XCTestCase {
    private func p(_ pct: Int, _ fw: Bool = false, _ fc: Bool = false) -> ThresholdAlert? {
        pendingThresholdAlert(percent: pct, warning: 75, critical: 90, firedWarning: fw, firedCritical: fc)
    }
    func test_belowWarning() { XCTAssertNil(p(50)) }
    func test_warningFires() { XCTAssertEqual(p(80), .warning) }
    func test_warningAlreadyFired() { XCTAssertNil(p(80, true, false)) }
    func test_criticalFires() { XCTAssertEqual(p(95), .critical) }
    func test_criticalPrecedenceOverUnfiredWarning() { XCTAssertEqual(p(95, false, false), .critical) }
    func test_noWarningAfterCritical() { XCTAssertNil(p(95, false, true)) }
    func test_bothFired() { XCTAssertNil(p(95, true, true)) }
    func test_exactBoundaries() {
        XCTAssertEqual(p(75), .warning)
        XCTAssertEqual(p(90), .critical)
    }
}
