import Foundation

public enum ThresholdAlert: Sendable, Equatable { case warning, critical }

/// Which (if any) session threshold alert to fire. Critical takes precedence; once
/// critical has fired, warning is suppressed too. nil when nothing should fire.
public func pendingThresholdAlert(percent: Int, warning: Int, critical: Int,
                                  firedWarning: Bool, firedCritical: Bool) -> ThresholdAlert? {
    if percent >= critical && !firedCritical { return .critical }
    if percent >= warning && !firedWarning && !firedCritical { return .warning }
    return nil
}
