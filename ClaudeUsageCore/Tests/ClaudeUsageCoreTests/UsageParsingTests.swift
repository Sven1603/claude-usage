import XCTest
@testable import ClaudeUsageCore

final class UsageParsingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_870_400) // 2026-06-19T12:00:00Z

    private func decode(_ json: String) throws -> UsageResponse {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(UsageResponse.self, from: Data(json.utf8))
    }

    func test_prefersLimitsSessionEntry() throws {
        let json = """
        {"limits":[
          {"kind":"weekly_all","percent":47,"resets_at":"2026-06-21T18:00:00Z"},
          {"kind":"session","percent":92,"resets_at":"2026-06-19T12:20:00.529775+00:00"}
        ],
        "five_hour":{"utilization":10,"resets_at":"2026-06-19T13:00:00Z"}}
        """
        let s = parseSessionUsage(try decode(json), now: now)
        XCTAssertEqual(s?.percent, 92)          // from limits[session], not five_hour
        XCTAssertEqual(s?.secondsToReset, 1200)
    }

    func test_fallsBackToFiveHour() throws {
        let json = """
        {"five_hour":{"utilization":73.0,"resets_at":"2026-06-19T12:30:00Z"}}
        """
        let s = parseSessionUsage(try decode(json), now: now)
        XCTAssertEqual(s?.percent, 73)
        XCTAssertEqual(s?.secondsToReset, 1800)
    }

    func test_nilWhenNoSessionOrFiveHour() throws {
        let json = """
        {"limits":[{"kind":"weekly_all","percent":47,"resets_at":"2026-06-21T18:00:00Z"}]}
        """
        XCTAssertNil(parseSessionUsage(try decode(json), now: now))
    }

    func test_realFixtureDecodes() throws {
        let url = Bundle.module.url(forResource: "usage_sample",
                                    withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let resp = try d.decode(UsageResponse.self, from: data)
        let s = parseSessionUsage(resp, now: now)
        XCTAssertEqual(s?.percent, 92) // fixture session percent
    }
}
