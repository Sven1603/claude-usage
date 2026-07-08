import Foundation

/// A display-ready usage limit (session or weekly), for the dropdown.
public struct UsageLimit: Equatable, Sendable {
    public let kind: String
    public let label: String
    public let percent: Int
    public let secondsToReset: Int
    public init(kind: String, label: String, percent: Int, secondsToReset: Int) {
        self.kind = kind; self.label = label
        self.percent = percent; self.secondsToReset = secondsToReset
    }
}

/// Parse the session + weekly limits from the usage response, in API order.
/// Non-session/non-weekly kinds are skipped.
public func parseUsageLimits(_ response: UsageResponse, now: Date) -> [UsageLimit] {
    (response.limits ?? []).compactMap { l -> UsageLimit? in
        guard let kind = l.kind, kind == "session" || kind.hasPrefix("weekly") else { return nil }
        return UsageLimit(
            kind: kind,
            label: label(for: kind, scope: l.scope),
            percent: clampPercent(l.percent),
            secondsToReset: secondsToReset(from: l.resetsAt, now: now))
    }
}

private func label(for kind: String, scope: LimitScope?) -> String {
    switch kind {
    case "session": return "5-hour session"
    case "weekly_all": return "Weekly (all)"
    case "weekly_scoped": return "Weekly (\(scope?.model?.displayName ?? "scoped"))"
    default: return "Weekly"
    }
}
