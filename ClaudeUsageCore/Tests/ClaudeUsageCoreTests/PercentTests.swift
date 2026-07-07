import XCTest
@testable import ClaudeUsageCore

final class PercentTests: XCTestCase {
    func test_roundsToNearestInt() {
        XCTAssertEqual(clampPercent(92.0), 92)
        XCTAssertEqual(clampPercent(91.6), 92)
        XCTAssertEqual(clampPercent(91.4), 91)
    }
    func test_clampsToRange() {
        XCTAssertEqual(clampPercent(-5), 0)
        XCTAssertEqual(clampPercent(150), 100)
    }
    func test_nilBecomesZero() {
        XCTAssertEqual(clampPercent(nil), 0)
    }
}
