import Foundation

public struct ScopeModel: Decodable, Sendable {
    public let displayName: String?
}

public struct LimitScope: Decodable, Sendable {
    public let model: ScopeModel?
}

/// One entry in the `limits` array. `resets_at`→`resetsAt`, `display_name`→
/// `displayName` via convertFromSnakeCase.
public struct Limit: Decodable, Sendable {
    public let kind: String?
    public let percent: Double?
    public let resetsAt: FlexibleReset?
    public let scope: LimitScope?
}

/// Legacy top-level window (`five_hour`, `seven_day`, `seven_day_sonnet`, ...).
public struct FiveHour: Decodable, Sendable {
    public let utilization: Double?
    public let resetsAt: FlexibleReset?
}

/// Top-level usage response. Every field is optional: plans differ (e.g. some
/// Max plans have no `five_hour` / session limit at all).
public struct UsageResponse: Decodable, Sendable {
    public let limits: [Limit]?
    public let fiveHour: FiveHour?
    public let sevenDay: FiveHour?
    public let sevenDaySonnet: FiveHour?
    public let sevenDayOpus: FiveHour?
}

/// The parsed session usage the UI cares about.
public struct SessionUsage: Equatable, Sendable {
    public let percent: Int
    public let secondsToReset: Int
    public init(percent: Int, secondsToReset: Int) {
        self.percent = percent
        self.secondsToReset = secondsToReset
    }
}

/// Prefer `limits[kind=="session"]`; fall back to `five_hour`; nil if neither.
/// Mirrors `parse_session_usage`.
public func parseSessionUsage(_ response: UsageResponse, now: Date) -> SessionUsage? {
    if let sess = response.limits?.first(where: { $0.kind == "session" }) {
        return SessionUsage(percent: clampPercent(sess.percent),
                            secondsToReset: secondsToReset(from: sess.resetsAt, now: now))
    }
    if let fh = response.fiveHour {
        return SessionUsage(percent: clampPercent(fh.utilization),
                            secondsToReset: secondsToReset(from: fh.resetsAt, now: now))
    }
    return nil
}
