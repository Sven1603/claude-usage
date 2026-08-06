import XCTest
@testable import ClaudeUsageCore

private struct FakeAssertions: WakeAssertionReading {
    let snap: WakeAssertionSnapshot
    func snapshot() -> WakeAssertionSnapshot { snap }
}

final class WakeAssertionsTests: XCTestCase {
    func test_noHoldersMeansNothingIsKeepingTheMacAwake() {
        let s = WakeAssertionSnapshot(holderCount: 0, processNames: [])
        XCTAssertFalse(s.isAnythingHoldingWake)
    }

    func test_holdersMeanSomethingIsKeepingTheMacAwake() {
        let s = WakeAssertionSnapshot(holderCount: 2, processNames: ["claude", "caffeinate"])
        XCTAssertTrue(s.isAnythingHoldingWake)
    }

    func test_protocolCanBeFaked() {
        let fake = FakeAssertions(snap: WakeAssertionSnapshot(holderCount: 1, processNames: ["claude"]))
        XCTAssertEqual(fake.snapshot().processNames, ["claude"])
    }

    func test_holderSummaryListsNamesInOrder() {
        XCTAssertEqual(holderSummary(["claude", "caffeinate"]), "claude, caffeinate")
    }

    func test_holderSummaryTruncatesLongLists() {
        XCTAssertEqual(holderSummary(["a", "b", "c", "d"]), "a, b and 2 more")
    }

    func test_holderSummaryOfNothing() {
        XCTAssertEqual(holderSummary([]), "nothing")
    }
}
