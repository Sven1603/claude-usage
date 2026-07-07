import XCTest
@testable import ClaudeUsageCore

final class UsageStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_870_400) // 2026-06-19T12:00:00Z

    func test_freshSuccessIsOk() {
        let s = deriveState(percent: 92, secondsToReset: 1200, orgName: "Acme",
                            lastSuccess: now, now: now, authFailed: false)
        XCTAssertEqual(s, .ok(percent: 92, secondsToReset: 1200, orgName: "Acme"))
    }
    func test_ticksCountdownLocally() {
        // 30s later, no new fetch: countdown should read 1200-30.
        let later = now.addingTimeInterval(30)
        let s = deriveState(percent: 92, secondsToReset: 1200, orgName: "Acme",
                            lastSuccess: now, now: later, authFailed: false)
        XCTAssertEqual(s, .ok(percent: 92, secondsToReset: 1170, orgName: "Acme"))
    }
    func test_staleAfterThreeMinutes() {
        let later = now.addingTimeInterval(200) // > 180s
        let s = deriveState(percent: 92, secondsToReset: 1200, orgName: "Acme",
                            lastSuccess: now, now: later, authFailed: false)
        XCTAssertEqual(s, .stale(percent: 92, secondsToReset: 1000, orgName: "Acme"))
    }
    func test_resettingWhenCountdownHitsZero() {
        let later = now.addingTimeInterval(1200)
        let s = deriveState(percent: 92, secondsToReset: 1200, orgName: "Acme",
                            lastSuccess: now, now: later, authFailed: false)
        XCTAssertEqual(s, .resetting)
    }
    func test_authErrorWins() {
        let s = deriveState(percent: 92, secondsToReset: 1200, orgName: "Acme",
                            lastSuccess: now, now: now, authFailed: true)
        XCTAssertEqual(s, .authError)
    }
    func test_noDataIsWaiting() {
        let s = deriveState(percent: nil, secondsToReset: nil, orgName: nil,
                            lastSuccess: nil, now: now, authFailed: false)
        XCTAssertEqual(s, .waiting)
    }
}
