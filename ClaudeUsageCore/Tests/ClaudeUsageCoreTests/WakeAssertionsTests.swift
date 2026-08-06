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

    // powerd holds a wake assertion the whole time the display is lit, which says
    // nothing about whether work is running. Verified live: with the lid open,
    // pmset lists powerd alongside the real caffeinate holders.
    func test_powerdIsNotCountedAsWork() {
        XCTAssertEqual(workHolders(from: ["powerd", "caffeinate"]), ["caffeinate"])
    }

    func test_onlyPowerdMeansNoWork() {
        XCTAssertTrue(workHolders(from: ["powerd"]).isEmpty)
    }

    func test_realHoldersPassThroughUnchanged() {
        XCTAssertEqual(workHolders(from: ["claude", "caffeinate"]), ["claude", "caffeinate"])
    }
}
