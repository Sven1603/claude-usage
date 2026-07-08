import XCTest
@testable import ClaudeUsageCore

final class FormatResetLongTests: XCTestCase {
    func test_now()       { XCTAssertEqual(formatResetLong(seconds: 0), "now") }
    func test_negative()  { XCTAssertEqual(formatResetLong(seconds: -5), "now") }
    func test_minutes()   { XCTAssertEqual(formatResetLong(seconds: 300), "5m") }
    func test_hoursMin()  { XCTAssertEqual(formatResetLong(seconds: 18300), "5h5m") }
    func test_oneDay()    { XCTAssertEqual(formatResetLong(seconds: 86400), "1d") }
    func test_daysHours() { XCTAssertEqual(formatResetLong(seconds: 194400), "2d 6h") }
    func test_dayAndHour(){ XCTAssertEqual(formatResetLong(seconds: 90000), "1d 1h") }
}
