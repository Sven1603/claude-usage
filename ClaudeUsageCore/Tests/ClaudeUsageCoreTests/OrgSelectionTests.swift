import XCTest
@testable import ClaudeUsageCore

final class OrgSelectionTests: XCTestCase {
    func test_prefersActiveOverIdle() {
        let idle = OrgUsage(uuid: "a", name: "Idle", percent: 99, secondsToReset: 0)
        let active = OrgUsage(uuid: "b", name: "Active", percent: 10, secondsToReset: 500)
        XCTAssertEqual(pickBestOrg([idle, active])?.uuid, "b")
    }
    func test_amongActiveChoosesHighestPercent() {
        let low = OrgUsage(uuid: "a", name: "Low", percent: 10, secondsToReset: 100)
        let high = OrgUsage(uuid: "b", name: "High", percent: 80, secondsToReset: 100)
        XCTAssertEqual(pickBestOrg([low, high])?.uuid, "b")
    }
    func test_tieKeepsFirst() {
        // Identical (active, percent) scores → earliest input element wins,
        // matching Python's `max` (first-wins), not Sequence.max (last-wins).
        let first = OrgUsage(uuid: "a", name: "First", percent: 50, secondsToReset: 100)
        let second = OrgUsage(uuid: "b", name: "Second", percent: 50, secondsToReset: 100)
        XCTAssertEqual(pickBestOrg([first, second])?.uuid, "a")
    }
    func test_emptyIsNil() {
        XCTAssertNil(pickBestOrg([]))
    }
}
