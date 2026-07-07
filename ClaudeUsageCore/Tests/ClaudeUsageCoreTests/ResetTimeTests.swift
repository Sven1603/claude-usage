import XCTest
@testable import ClaudeUsageCore

final class ResetTimeTests: XCTestCase {
    // Fixed reference "now" = 2026-06-19T12:00:00Z = 1_781_870_400
    // (Note: 1_782_216_000 in the plan was a typo — that is 2026-06-23T12:00:00Z)
    private let now = Date(timeIntervalSince1970: 1_781_870_400)

    func test_isoStringWithMicrosecondsAndOffset() {
        let r = FlexibleReset.iso("2026-06-19T12:20:00.529775+00:00")
        XCTAssertEqual(secondsToReset(from: r, now: now), 1200) // 20 min
    }
    func test_isoStringWithZSuffix() {
        let r = FlexibleReset.iso("2026-06-19T12:10:00Z")
        XCTAssertEqual(secondsToReset(from: r, now: now), 600)
    }
    func test_epochNumber() {
        let r = FlexibleReset.epoch(now.timeIntervalSince1970 + 100)
        XCTAssertEqual(secondsToReset(from: r, now: now), 100)
    }
    func test_pastResetClampsToZero() {
        let r = FlexibleReset.iso("2026-06-19T11:00:00Z")
        XCTAssertEqual(secondsToReset(from: r, now: now), 0)
    }
    func test_noneAndGarbageAreZero() {
        XCTAssertEqual(secondsToReset(from: FlexibleReset.none, now: now), 0)
        XCTAssertEqual(secondsToReset(from: nil, now: now), 0)
        XCTAssertEqual(secondsToReset(from: FlexibleReset.iso("not-a-date"), now: now), 0)
    }

    // MARK: - Decode ordering (init(from:))

    // Optional field: mirrors how Limit/FiveHour declare `resetsAt`.
    private struct Wrapper: Decodable {
        let resetsAt: FlexibleReset?
    }

    private func decodeWrapper(_ json: String) throws -> FlexibleReset? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Wrapper.self, from: Data(json.utf8)).resetsAt
    }

    // Non-optional field: forces FlexibleReset.init(from:) to run even on a
    // JSON null, exercising its own `.none` branch (an optional field would
    // short-circuit to Swift's Optional == nil via decodeIfPresent instead).
    private struct RequiredWrapper: Decodable {
        let resetsAt: FlexibleReset
    }

    private func decodeRequired(_ json: String) throws -> FlexibleReset {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(RequiredWrapper.self, from: Data(json.utf8)).resetsAt
    }

    func test_decodesEpochNumberAsEpoch() throws {
        let r = try decodeWrapper(#"{"resets_at": 1781870500}"#)
        XCTAssertEqual(r, .epoch(1781870500))
    }
    func test_decodesIsoStringAsIso() throws {
        let r = try decodeWrapper(#"{"resets_at": "2026-06-19T12:20:00Z"}"#)
        XCTAssertEqual(r, .iso("2026-06-19T12:20:00Z"))
    }
    func test_optionalFieldNullDecodesToNilOptional() throws {
        // A JSON null on an optional field is decoded by Swift's synthesized
        // decodeIfPresent as Optional.none — init(from:) is not invoked.
        let r = try decodeWrapper(#"{"resets_at": null}"#)
        XCTAssertNil(r)
    }
    func test_requiredFieldNullDecodesToNoneCase() throws {
        // A JSON null on a required field DOES invoke init(from:), which maps
        // the null to the enum's own `.none` case.
        let r = try decodeRequired(#"{"resets_at": null}"#)
        XCTAssertEqual(r, FlexibleReset.none)
    }
    func test_requiredFieldEpochDecodesToEpoch() throws {
        // Guards the Double-before-String decode order on a required field.
        let r = try decodeRequired(#"{"resets_at": 1781870500}"#)
        XCTAssertEqual(r, .epoch(1781870500))
    }
}
