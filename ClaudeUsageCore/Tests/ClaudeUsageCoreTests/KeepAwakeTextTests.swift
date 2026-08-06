import XCTest
@testable import ClaudeUsageCore

final class KeepAwakeTextTests: XCTestCase {
    func test_offSubtitle() {
        XCTAssertEqual(keepAwakeSubtitle(.off),
                       "Your Mac sleeps normally when you close the lid.")
    }

    func test_needsSetupSubtitle() {
        XCTAssertEqual(keepAwakeSubtitle(.needsSetup), "Needs a one-time admin approval.")
    }

    func test_activeSubtitleListsHoldersTimeAndBattery() {
        let s = keepAwakeSubtitle(.active(holders: ["claude", "caffeinate"],
                                          secondsLeft: 11_520, batteryPercent: 64, onAC: false))
        XCTAssertEqual(s, "Awake for claude, caffeinate · 3h12m left · 64%")
    }

    func test_activeSubtitleOmitsBatteryOnAC() {
        let s = keepAwakeSubtitle(.active(holders: ["claude"],
                                          secondsLeft: 3600, batteryPercent: 64, onAC: true))
        XCTAssertEqual(s, "Awake for claude · 1h0m left")
    }

    func test_graceSubtitleCountsDown() {
        XCTAssertEqual(keepAwakeSubtitle(.grace(secondsUntilSleep: 100)),
                       "Nothing running, sleeping in 1m 40s")
    }

    func test_graceSubtitleUnderAMinute() {
        XCTAssertEqual(keepAwakeSubtitle(.grace(secondsUntilSleep: 40)),
                       "Nothing running, sleeping in 40s")
    }

    func test_failedSubtitleSurfacesTheProblem() {
        XCTAssertEqual(keepAwakeSubtitle(.failed("Helper not approved")),
                       "Helper not approved")
    }

    func test_shortCountdownFormatting() {
        XCTAssertEqual(formatShortCountdown(seconds: 0), "0s")
        XCTAssertEqual(formatShortCountdown(seconds: 59), "59s")
        XCTAssertEqual(formatShortCountdown(seconds: 60), "1m 0s")
        XCTAssertEqual(formatShortCountdown(seconds: 125), "2m 5s")
        XCTAssertEqual(formatShortCountdown(seconds: -5), "0s")
    }

    func test_restoreNotificationBodies() {
        XCTAssertEqual(sleepRestoredMessage(for: .noActiveWork, capHours: 4),
                       "No active sessions, so your Mac can sleep again.")
        XCTAssertEqual(sleepRestoredMessage(for: .capReached, capHours: 4),
                       "The 4 hour limit was reached, so your Mac can sleep again.")
        XCTAssertEqual(sleepRestoredMessage(for: .lowBattery, capHours: 4),
                       "Battery dropped below 20%, so your Mac can sleep again.")
    }

    func test_capReachedBodyUsesTheConfiguredCap() {
        XCTAssertEqual(sleepRestoredMessage(for: .capReached, capHours: 1),
                       "The 1 hour limit was reached, so your Mac can sleep again.")
    }

    func test_clockAnomalyBody() {
        XCTAssertEqual(sleepRestoredMessage(for: .clockAnomaly, capHours: 4),
                       "The system clock changed, so your Mac can sleep again.")
    }
}
