import Foundation

public enum UsageSeverity: Sendable, Equatable { case safe, warning, critical }

/// <75 safe, 75–89 warning, ≥90 critical (matches the menu-bar bar colors).
public func severity(forPercent p: Int) -> UsageSeverity {
    if p >= 90 { return .critical }
    if p >= 75 { return .warning }
    return .safe
}

/// Window length for a limit kind: session = 5h, anything weekly = 7d.
public func windowSeconds(forKind kind: String) -> Int {
    return kind == "session" ? 5 * 3600 : 7 * 24 * 3600
}

/// True when usage outruns a linear "sustainable" pace — i.e. at the current rate
/// you'd exhaust before reset. Ignores the first 5% of the window (avoids early
/// jitter) and requires percent to exceed the elapsed fraction by >5 points.
public func isOverPace(percent: Int, secondsToReset: Int, windowSeconds: Int) -> Bool {
    guard windowSeconds > 0 else { return false }
    let remaining = max(0, min(secondsToReset, windowSeconds))
    let elapsed = windowSeconds - remaining
    guard elapsed > windowSeconds / 20 else { return false }
    let expected = Double(elapsed) / Double(windowSeconds) * 100.0
    return Double(percent) > expected + 5.0
}
