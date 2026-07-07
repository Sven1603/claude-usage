import Foundation

/// Format seconds as "1h29m" or "29m". Mirrors the firmware countdown display.
public func formatCountdown(seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    return h > 0 ? "\(h)h\(m)m" : "\(m)m"
}
