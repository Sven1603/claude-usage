import XCTest
@testable import ClaudeUsageCore

final class CountdownTests: XCTestCase {
    func test_hoursAndMinutes() { XCTAssertEqual(formatCountdown(seconds: 5340), "1h29m") }
    func test_minutesOnly()     { XCTAssertEqual(formatCountdown(seconds: 1740), "29m") }
    func test_zero()            { XCTAssertEqual(formatCountdown(seconds: 0), "0m") }
    func test_negativeClamps()  { XCTAssertEqual(formatCountdown(seconds: -10), "0m") }
    func test_roundsDownToMinute() { XCTAssertEqual(formatCountdown(seconds: 119), "1m") }
}
