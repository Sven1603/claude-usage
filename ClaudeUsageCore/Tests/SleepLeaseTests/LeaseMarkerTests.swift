import XCTest
@testable import SleepLease

final class LeaseMarkerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_noMarkerMeansNothingToRestore() {
        XCTAssertFalse(shouldRestoreOnBoot(marker: nil))
    }

    func test_ourMarkerMeansRestore() {
        let m = LeaseMarker(ownedByUs: true, sleepWasAlreadyDisabled: false, setAt: t0)
        XCTAssertTrue(shouldRestoreOnBoot(marker: m))
    }

    // The user ran `sudo pmset -a disablesleep 1` themselves before ever using
    // the toggle. We recorded that we found it already on, and we must not undo it.
    func test_userSettingIsNeverUndone() {
        let m = LeaseMarker(ownedByUs: true, sleepWasAlreadyDisabled: true, setAt: t0)
        XCTAssertFalse(shouldRestoreOnBoot(marker: m))
    }

    // Nothing writes a marker with ownedByUs false today, but the reader must not
    // depend on the writer's discipline: a marker that is not ours is not ours to act on.
    func test_markerNotOwnedByUsIsNeverActedOn() {
        let m = LeaseMarker(ownedByUs: false, sleepWasAlreadyDisabled: false, setAt: t0)
        XCTAssertFalse(shouldRestoreOnBoot(marker: m))
    }

    func test_roundTripsThroughJSON() throws {
        let m = LeaseMarker(ownedByUs: true, sleepWasAlreadyDisabled: false, setAt: t0)
        let data = try m.encoded()
        XCTAssertEqual(try LeaseMarker.decoded(from: data), m)
    }

    func test_decodingGarbageThrows() {
        XCTAssertThrowsError(try LeaseMarker.decoded(from: Data("not json".utf8)))
    }
}
