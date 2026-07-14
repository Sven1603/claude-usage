import Foundation

/// An org from `GET /api/organizations`.
public struct Org: Decodable, Equatable, Sendable {
    public let uuid: String
    public let name: String?
    public let capabilities: [String]?
    public let ravenType: String?
    public let billingType: String?
}

/// An org paired with its parsed session usage, for selection.
public struct OrgUsage: Equatable, Sendable {
    public let uuid: String
    public let name: String?
    public let percent: Int
    public let secondsToReset: Int
    public init(uuid: String, name: String?, percent: Int, secondsToReset: Int) {
        self.uuid = uuid; self.name = name
        self.percent = percent; self.secondsToReset = secondsToReset
    }
}

/// Active (secondsToReset > 0) beats idle; ties broken by higher percent.
/// Mirrors the scoring in `pick_org_uuid` — including its FIRST-wins tie-break:
/// among equal `(active, percent)` scores the earliest element in the input
/// wins. `Sequence.max(by:)` returns the LAST maximal element, so we fold
/// manually with a strict `>` comparison (replace only on a strictly better
/// score) to match Python's `max`, which keeps the first on ties.
public func pickBestOrg(_ candidates: [OrgUsage]) -> OrgUsage? {
    func score(_ o: OrgUsage) -> (Int, Int) {
        (o.secondsToReset > 0 ? 1 : 0, o.percent)
    }
    var best: OrgUsage?
    for candidate in candidates {
        guard let current = best else { best = candidate; continue }
        if score(candidate) > score(current) { best = candidate }
    }
    return best
}
