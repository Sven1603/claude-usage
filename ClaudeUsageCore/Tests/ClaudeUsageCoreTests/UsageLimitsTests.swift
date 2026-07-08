import XCTest
@testable import ClaudeUsageCore

final class UsageLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_870_400) // 2026-06-19T12:00:00Z

    private func decode(_ json: String) throws -> UsageResponse {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(UsageResponse.self, from: Data(json.utf8))
    }

    func test_labelsSessionWeeklyAllAndScoped() throws {
        let json = """
        {"limits":[
          {"kind":"session","percent":79,"resets_at":"2026-06-19T15:05:00Z"},
          {"kind":"weekly_all","percent":47,"resets_at":"2026-06-19T18:00:00Z"},
          {"kind":"weekly_scoped","percent":6,"resets_at":"2026-06-19T18:00:00Z",
           "scope":{"model":{"display_name":"Fable"}}}
        ]}
        """
        let limits = parseUsageLimits(try decode(json), now: now)
        XCTAssertEqual(limits.map(\.label),
                       ["5-hour session", "Weekly (all)", "Weekly (Fable)"])
        XCTAssertEqual(limits.map(\.percent), [79, 47, 6])
        XCTAssertEqual(limits[0].secondsToReset, 3 * 3600 + 5 * 60) // 3h5m
    }

    func test_scopedWithNoModelName() throws {
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":"2026-06-19T18:00:00Z"}]}
        """
        XCTAssertEqual(parseUsageLimits(try decode(json), now: now).first?.label, "Weekly (scoped)")
    }

    func test_skipsUnknownKinds() throws {
        let json = """
        {"limits":[
          {"kind":"session","percent":1,"resets_at":"2026-06-19T13:00:00Z"},
          {"kind":"spend","percent":0,"resets_at":null},
          {"kind":"weekly_all","percent":2,"resets_at":"2026-06-19T13:00:00Z"}
        ]}
        """
        XCTAssertEqual(parseUsageLimits(try decode(json), now: now).map(\.kind),
                       ["session", "weekly_all"])
    }

    func test_realFixture() throws {
        let url = Bundle.module.url(forResource: "usage_sample",
                                    withExtension: "json", subdirectory: "Fixtures")!
        let resp = try { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
            return try d.decode(UsageResponse.self, from: Data(contentsOf: url)) }()
        let labels = parseUsageLimits(resp, now: now).map(\.label)
        XCTAssertTrue(labels.contains("5-hour session"))
        XCTAssertTrue(labels.contains("Weekly (all)"))
        // Guards scope decoding against the real API payload shape.
        XCTAssertTrue(labels.contains("Weekly (Sonnet)"))
    }
}
