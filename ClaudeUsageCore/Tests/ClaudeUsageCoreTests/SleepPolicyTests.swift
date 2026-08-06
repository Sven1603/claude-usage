import XCTest
@testable import ClaudeUsageCore

final class SleepPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Defaults describe a healthy world: on AC, full battery, just enabled,
    /// work actively running. Each test perturbs one axis.
    private func world(elapsed: TimeInterval = 0,
                       cap: TimeInterval = 4 * 3600,
                       sinceAssertion: TimeInterval = 0,
                       battery: Int = 100,
                       onAC: Bool = true) -> SleepWorld {
        let now = t0.addingTimeInterval(elapsed)
        return SleepWorld(now: now,
                          enabledAt: t0,
                          cap: cap,
                          lastAssertionAt: now.addingTimeInterval(-sinceAssertion),
                          batteryPercent: battery,
                          onACPower: onAC)
    }

    func test_healthyWorldKeepsAwake() {
        XCTAssertEqual(decideSleep(world()), .keepAwake)
    }

    func test_lowBatteryOnBatteryRestores() {
        XCTAssertEqual(decideSleep(world(battery: 19, onAC: false)), .restore(.lowBattery))
    }

    func test_batteryFloorIsInclusive() {
        XCTAssertEqual(decideSleep(world(battery: 20, onAC: false)), .restore(.lowBattery))
        XCTAssertEqual(decideSleep(world(battery: 21, onAC: false)), .keepAwake)
    }

    func test_lowBatteryIgnoredOnAC() {
        XCTAssertEqual(decideSleep(world(battery: 5, onAC: true)), .keepAwake)
    }

    func test_capReachedRestores() {
        XCTAssertEqual(decideSleep(world(elapsed: 4 * 3600)), .restore(.capReached))
    }

    func test_justUnderCapKeepsAwake() {
        XCTAssertEqual(decideSleep(world(elapsed: 4 * 3600 - 1)), .keepAwake)
    }

    func test_noActiveWorkRestoresAfterGrace() {
        XCTAssertEqual(decideSleep(world(sinceAssertion: 120)), .restore(.noActiveWork))
    }

    func test_withinGraceKeepsAwake() {
        XCTAssertEqual(decideSleep(world(sinceAssertion: 119)), .keepAwake)
    }

    // lastAssertionAt is seeded to enabledAt, so a machine enabled while Claude
    // is between turns must not restore immediately.
    func test_seededAtEnableDoesNotRestoreImmediately() {
        let w = SleepWorld(now: t0, enabledAt: t0, cap: 4 * 3600,
                           lastAssertionAt: t0, batteryPercent: 100, onACPower: false)
        XCTAssertEqual(decideSleep(w), .keepAwake)
    }

    func test_batteryOutranksCap() {
        XCTAssertEqual(decideSleep(world(elapsed: 5 * 3600, battery: 10, onAC: false)),
                       .restore(.lowBattery))
    }

    func test_capOutranksNoActiveWork() {
        XCTAssertEqual(decideSleep(world(elapsed: 5 * 3600, sinceAssertion: 600)),
                       .restore(.capReached))
    }

    func test_oneHourCapIsHonoured() {
        XCTAssertEqual(decideSleep(world(elapsed: 3600, cap: 3600)), .restore(.capReached))
    }

    // A backwards clock step would make both the cap and grace differences
    // negative, so every threshold comparison reads false. Without an explicit
    // check that is an indefinite .keepAwake, i.e. silent battery drain.
    func test_clockBeforeEnableRestores() {
        XCTAssertEqual(decideSleep(world(elapsed: -60)), .restore(.clockAnomaly))
    }

    func test_assertionTimestampInFutureRestores() {
        let w = SleepWorld(now: t0, enabledAt: t0, cap: 4 * 3600,
                           lastAssertionAt: t0.addingTimeInterval(60),
                           batteryPercent: 100, onACPower: true)
        XCTAssertEqual(decideSleep(w), .restore(.clockAnomaly))
    }

    // A low battery is the more actionable cause, so it still wins over a bad clock.
    func test_lowBatteryOutranksClockAnomaly() {
        XCTAssertEqual(decideSleep(world(elapsed: -60, battery: 10, onAC: false)),
                       .restore(.lowBattery))
    }

    // Non-positive caps restore immediately rather than never. Incidental to the
    // operator, so pinned here against a future "cleanup" that inverts it.
    func test_nonPositiveCapRestoresImmediately() {
        XCTAssertEqual(decideSleep(world(cap: 0)), .restore(.capReached))
    }
}
