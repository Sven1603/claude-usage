import Foundation

/// `resets_at` from the API is either an ISO8601 string or an epoch number
/// (or absent). Decodes from a single JSON value. Mirrors `_parse_reset`.
public enum FlexibleReset: Decodable, Equatable, Sendable {
    case iso(String)
    case epoch(Double)
    case none

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .none; return }
        // Decode order matters: try Double before String. JSON numbers are
        // unquoted, so an epoch would also NOT decode as String — but an ISO
        // string must never be tried as Double first. Do not reorder.
        if let d = try? c.decode(Double.self) { self = .epoch(d); return }
        if let s = try? c.decode(String.self) { self = .iso(s); return }
        self = .none
    }
}

private let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseISO(_ s: String) -> Date? {
    // Apple's ISO8601DateFormatter only reliably parses millisecond fractions,
    // but the API sends microseconds (…529775+00:00). Strip any fractional
    // seconds and parse the whole-second form; fall back to the fractional
    // formatter for millisecond-only strings.
    let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "",
                                          options: .regularExpression)
    return isoPlain.date(from: stripped) ?? isoWithFraction.date(from: s)
}

/// Whole seconds from `now` until the reset. Never negative. 0 on missing/garbage.
public func secondsToReset(from reset: FlexibleReset?, now: Date) -> Int {
    let target: Date?
    switch reset {
    case .some(.iso(let s)): target = parseISO(s)
    case .some(.epoch(let e)): target = Date(timeIntervalSince1970: e)
    case .some(.none), .none: target = nil
    }
    guard let target else { return 0 }
    return max(0, Int(target.timeIntervalSince(now)))
}
