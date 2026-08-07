import Foundation

/// What the dropdown row is showing. Derived by SleepGuard, rendered by KeepAwakeRow.
public enum KeepAwakeUIState: Sendable, Equatable {
    case off
    case needsSetup
    case active(holders: [String], secondsLeft: Int, batteryPercent: Int, onAC: Bool)
    case grace(secondsUntilSleep: Int)
    case failed(String)
}

/// "2m 5s" / "40s". Used for the short grace countdown, where formatResetLong's
/// minute resolution would sit at "1m" for a whole minute.
public func formatShortCountdown(seconds: Int) -> String {
    let s = max(0, seconds)
    return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
}

public func keepAwakeSubtitle(_ state: KeepAwakeUIState) -> String {
    switch state {
    case .off:
        return "Your Mac sleeps normally when you close the lid."
    case .needsSetup:
        return "Needs a one-time admin approval."
    case let .active(holders, secondsLeft, batteryPercent, onAC):
        var parts = ["Awake for \(holderSummary(holders))",
                     "\(formatResetLong(seconds: secondsLeft)) left"]
        if !onAC { parts.append("\(batteryPercent)%") }
        return parts.joined(separator: " · ")
    case let .grace(secondsUntilSleep):
        return "Nothing running, sleeping in \(formatShortCountdown(seconds: secondsUntilSleep))"
    case let .failed(message):
        return message
    }
}

/// The explainer sheet's line about the time limit, read from the configured cap
/// rather than hardcoded: a user who has already picked 1h or 8h in Settings must
/// not be told the limit is 4 hours when they reinstall the helper.
public func keepAwakeCapLine(capHours: Int) -> String {
    let hours = max(1, capHours)
    return "The time limit is reached (\(hours) \(hours == 1 ? "hour" : "hours"))"
}

public func sleepRestoredMessage(for reason: SleepRestoreReason, capHours: Int) -> String {
    switch reason {
    case .noActiveWork:
        return "No active sessions, so your Mac can sleep again."
    case .capReached:
        return "The \(capHours) hour limit was reached, so your Mac can sleep again."
    case .lowBattery:
        return "Battery dropped below \(sleepBatteryFloor)%, so your Mac can sleep again."
    case .clockAnomaly:
        return "The system clock changed, so your Mac can sleep again."
    }
}
