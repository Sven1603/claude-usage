import Foundation

public enum UsageState: Equatable, Sendable {
    case waiting
    case ok(percent: Int, secondsToReset: Int, orgName: String?)
    case stale(percent: Int, secondsToReset: Int, orgName: String?)
    case authError
    case resetting
}

/// How long before a successful fetch is considered stale.
public let staleThreshold: TimeInterval = 180

/// Pure state derivation. Inputs are the last successful values + the current
/// clock; the countdown is recomputed locally so it ticks between fetches.
public func deriveState(percent: Int?, secondsToReset: Int?, orgName: String?,
                        lastSuccess: Date?, now: Date, authFailed: Bool) -> UsageState {
    if authFailed { return .authError }
    guard let percent, let secondsToReset, let lastSuccess else { return .waiting }
    let elapsed = Int(now.timeIntervalSince(lastSuccess))
    let remaining = max(0, secondsToReset - max(0, elapsed))
    // `.resetting` is intentionally checked before `.stale`: a rolled-over
    // window should read "resetting" even if the last fetch is also stale.
    if remaining == 0 { return .resetting }
    if elapsed > Int(staleThreshold) {
        return .stale(percent: percent, secondsToReset: remaining, orgName: orgName)
    }
    return .ok(percent: percent, secondsToReset: remaining, orgName: orgName)
}
