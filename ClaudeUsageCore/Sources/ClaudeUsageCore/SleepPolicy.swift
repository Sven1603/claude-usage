import Foundation

public enum SleepRestoreReason: String, Sendable, Equatable, Codable {
    case lowBattery, capReached, noActiveWork, clockAnomaly
}

public enum SleepDecision: Sendable, Equatable {
    case keepAwake
    case restore(SleepRestoreReason)
}

/// Everything the policy needs, captured at one instant so the decision is pure.
public struct SleepWorld: Sendable, Equatable {
    public let now: Date
    public let enabledAt: Date
    /// Must be finite and positive. `decideSleep` is not the enforcement point for
    /// "no unlimited option" — the Settings picker is — but a non-positive cap
    /// restores immediately rather than never, which is the safe direction.
    public let cap: TimeInterval
    /// Last time anything held a wake assertion. Seeded to `enabledAt` on enable
    /// so the grace clock never fires just because Claude is between turns.
    public let lastAssertionAt: Date
    public let batteryPercent: Int
    public let onACPower: Bool

    public init(now: Date, enabledAt: Date, cap: TimeInterval,
                lastAssertionAt: Date, batteryPercent: Int, onACPower: Bool) {
        self.now = now
        self.enabledAt = enabledAt
        self.cap = cap
        self.lastAssertionAt = lastAssertionAt
        self.batteryPercent = batteryPercent
        self.onACPower = onACPower
    }
}

/// How long nothing may hold a wake assertion before we give the lease back.
/// Absorbs the gaps between Claude Code turns.
public let sleepGracePeriod: TimeInterval = 120

/// Below this, on battery, sleep comes back regardless of anything else.
public let sleepBatteryFloor = 20

public let sleepCapDefault: TimeInterval = 4 * 3600

/// Whether to keep the machine awake. Checked most-serious-first so the
/// notification can name the real cause.
///
/// The clock check is not paranoia: both the cap and the grace check are
/// differences against `now`, so if the clock steps backwards (an NTP
/// correction) or a caller stamps an inconsistent timestamp, both differences go
/// negative, every threshold comparison is false, and a naive implementation
/// returns `.keepAwake` forever. That is silent, unbounded battery drain — the
/// one failure this feature must not have. Anomalous ordering therefore restores
/// sleep. It sits after the battery check so a genuinely low battery still
/// reports the more actionable cause.
public func decideSleep(_ w: SleepWorld) -> SleepDecision {
    if !w.onACPower && w.batteryPercent <= sleepBatteryFloor { return .restore(.lowBattery) }
    if w.now < w.enabledAt || w.now < w.lastAssertionAt { return .restore(.clockAnomaly) }
    if w.now.timeIntervalSince(w.enabledAt) >= w.cap { return .restore(.capReached) }
    if w.now.timeIntervalSince(w.lastAssertionAt) >= sleepGracePeriod { return .restore(.noActiveWork) }
    return .keepAwake
}
