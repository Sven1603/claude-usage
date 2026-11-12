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
/// Non-session/non-weekly kinds are skipped. The session limit is optional: some
/// plans only have weekly limits. When the `limits` array is absent or empty,
/// falls back to the legacy top-level windows (`five_hour`, `seven_day`, ...).
public func parseUsageLimits(_ response: UsageResponse, now: Date) -> [UsageLimit] {
    let fromArray = (response.limits ?? []).compactMap { l -> UsageLimit? in
        guard let kind = l.kind, kind == "session" || kind.hasPrefix("weekly") else { return nil }
        return UsageLimit(
            kind: kind,
            label: label(for: kind, scope: l.scope),
            percent: clampPercent(l.percent),
            secondsToReset: secondsToReset(from: l.resetsAt, now: now))
    }
    return fromArray.isEmpty ? legacyLimits(response, now: now) : fromArray
}

private func legacyLimits(_ r: UsageResponse, now: Date) -> [UsageLimit] {
    let windows: [(String, String, FiveHour?)] = [
        ("session", "5-hour session", r.fiveHour),
        ("weekly_all", "Weekly (all)", r.sevenDay),
        ("weekly_scoped", "Weekly (Sonnet)", r.sevenDaySonnet),
        ("weekly_scoped", "Weekly (Opus)", r.sevenDayOpus),
    ]
    return windows.compactMap { kind, label, w in
        guard let w else { return nil }   // null utilization reads as 0%, as before
        return UsageLimit(kind: kind, label: label,
                          percent: clampPercent(w.utilization),
                          secondsToReset: secondsToReset(from: w.resetsAt, now: now))
    }
}

/// The one limit the menu bar shows: the session limit when the plan has one,
/// otherwise the most-used limit (the one that will stop you first). Limits with
/// a reset time beat ones without (an unused window has no `resets_at`, and would
/// otherwise read "Resetting…" forever). Ties keep the first in API order. nil
/// when there are no limits.
public func headlineLimit(_ limits: [UsageLimit]) -> UsageLimit? {
    if let session = limits.first(where: { $0.kind == "session" }) { return session }
    func score(_ l: UsageLimit) -> (Int, Int) { (l.secondsToReset > 0 ? 1 : 0, l.percent) }
    var best: UsageLimit?
    for l in limits where best == nil || score(l) > score(best!) { best = l }
    return best
}

private func label(for kind: String, scope: LimitScope?) -> String {
    switch kind {
    case "session": return "5-hour session"
    case "weekly_all": return "Weekly (all)"
    case "weekly_scoped": return "Weekly (\(scope?.model?.displayName ?? "scoped"))"
    default: return "Weekly"
    }
}
