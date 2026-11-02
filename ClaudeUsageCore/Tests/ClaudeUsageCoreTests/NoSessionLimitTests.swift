import XCTest
@testable import ClaudeUsageCore

/// Some plans (seen on a Max 20x account, Nov 2026) no longer have a 5-hour session
/// limit: `five_hour` is null and `limits` holds only weekly entries. Everything
/// must keep working off the weekly limits instead of treating that as an error.
final class NoSessionLimitTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-02T15:00:00Z")!

    private func fixture(_ name: String) throws -> UsageResponse {
        let url = Bundle.module.url(forResource: name, withExtension: "json",
                                    subdirectory: "Fixtures")!
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(UsageResponse.self, from: Data(contentsOf: url))
    }

    private func decode(_ json: String) throws -> UsageResponse {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(UsageResponse.self, from: Data(json.utf8))
    }

    // MARK: real payloads

    func test_noSessionFixture_parsesWeeklyLimits() throws {
        let limits = parseUsageLimits(try fixture("usage_2026_11_no_session"), now: now)
        XCTAssertEqual(limits.map(\.kind), ["weekly_all", "weekly_scoped"])
        XCTAssertEqual(limits.map(\.label), ["Weekly (all)", "Weekly (Fable)"])
        XCTAssertEqual(limits.first?.percent, 100)
        XCTAssertEqual(limits.first?.secondsToReset, 25 * 3600)
    }

    func test_noSessionFixture_headlineIsMostUsedWeekly() throws {
        let limits = parseUsageLimits(try fixture("usage_2026_11_no_session"), now: now)
        XCTAssertEqual(headlineLimit(limits)?.kind, "weekly_all")
    }

    func test_sessionFixture_headlineIsSession() throws {
        let limits = parseUsageLimits(try fixture("usage_2026_11"), now: now)
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(headlineLimit(limits)?.kind, "session")
        XCTAssertEqual(headlineLimit(limits)?.percent, 51)
    }

    // MARK: headline selection

    func test_headline_prefersSessionEvenWhenWeeklyIsHigher() {
        let limits = [UsageLimit(kind: "weekly_all", label: "", percent: 95, secondsToReset: 10),
                      UsageLimit(kind: "session", label: "", percent: 20, secondsToReset: 10)]
        XCTAssertEqual(headlineLimit(limits)?.kind, "session")
    }

    func test_headline_tieKeepsFirst() {
        let limits = [UsageLimit(kind: "weekly_all", label: "", percent: 40, secondsToReset: 10),
                      UsageLimit(kind: "weekly_scoped", label: "", percent: 40, secondsToReset: 10)]
        XCTAssertEqual(headlineLimit(limits)?.kind, "weekly_all")
    }

    func test_headline_nilWhenEmpty() {
        XCTAssertNil(headlineLimit([]))
    }

    // MARK: legacy fallback when `limits` is absent

    func test_legacyFallback_withoutLimitsArray() throws {
        let json = """
        {"five_hour":null,
         "seven_day":{"utilization":100,"resets_at":"2026-11-03T16:00:00Z"},
         "seven_day_sonnet":{"utilization":12,"resets_at":"2026-11-03T16:00:00Z"},
         "seven_day_opus":null}
        """
        let limits = parseUsageLimits(try decode(json), now: now)
        XCTAssertEqual(limits.map(\.kind), ["weekly_all", "weekly_scoped"])
        XCTAssertEqual(limits.map(\.label), ["Weekly (all)", "Weekly (Sonnet)"])
        XCTAssertEqual(headlineLimit(limits)?.percent, 100)
    }

    func test_legacyFallback_includesFiveHour() throws {
        let json = """
        {"five_hour":{"utilization":30,"resets_at":"2026-11-02T16:00:00Z"},
         "seven_day":{"utilization":5,"resets_at":"2026-11-03T16:00:00Z"}}
        """
        let limits = parseUsageLimits(try decode(json), now: now)
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all"])
    }

    func test_emptyLimitsArrayAlsoFallsBack() throws {
        let json = """
        {"limits":[], "seven_day":{"utilization":9,"resets_at":"2026-11-03T16:00:00Z"}}
        """
        XCTAssertEqual(parseUsageLimits(try decode(json), now: now).map(\.kind), ["weekly_all"])
    }

    func test_nothingAtAll_isEmpty() throws {
        XCTAssertTrue(parseUsageLimits(try decode("{}"), now: now).isEmpty)
    }

    func test_headline_skipsLimitWithoutResetTimeWhenAnotherHasOne() {
        // An unused window (0%, resets_at null) must not become the headline, or the
        // menu bar would read "Resetting…" forever.
        let limits = [UsageLimit(kind: "weekly_all", label: "", percent: 0, secondsToReset: 0),
                      UsageLimit(kind: "weekly_scoped", label: "", percent: 0, secondsToReset: 3600)]
        XCTAssertEqual(headlineLimit(limits)?.kind, "weekly_scoped")
    }

    func test_headline_allWithoutResetStillReturnsOne() {
        let limits = [UsageLimit(kind: "weekly_all", label: "", percent: 3, secondsToReset: 0)]
        XCTAssertEqual(headlineLimit(limits)?.kind, "weekly_all")
    }

    func test_legacyFiveHourWithNullUtilizationIsZero() throws {
        let json = #"{"five_hour":{"utilization":null,"resets_at":null}}"#
        XCTAssertEqual(parseUsageLimits(try decode(json), now: now).map(\.percent), [0])
    }
}
