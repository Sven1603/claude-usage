import Foundation

/// Format seconds as "1h29m" or "29m". Mirrors the firmware countdown display.
public func formatCountdown(seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    return h > 0 ? "\(h)h\(m)m" : "\(m)m"
}

/// Day-aware reset formatting for the dropdown: "2d 6h", "5h5m", "5m", "now".
public func formatResetLong(seconds: Int) -> String {
    if seconds <= 0 { return "now" }
    let d = seconds / 86400
    let h = (seconds % 86400) / 3600
    let m = (seconds % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}
