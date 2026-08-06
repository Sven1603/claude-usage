import Foundation
import IOKit.ps

public struct PowerSnapshot: Sendable, Equatable {
    public let batteryPercent: Int
    public let onACPower: Bool

    public init(batteryPercent: Int, onACPower: Bool) {
        self.batteryPercent = batteryPercent
        self.onACPower = onACPower
    }
}

public protocol PowerSourceReading: Sendable {
    func snapshot() -> PowerSnapshot
}

/// Reads battery level and power source from IOKit. Unprivileged.
public struct IOKitPowerSource: PowerSourceReading {
    public init() {}

    public func snapshot() -> PowerSnapshot {
        // A desktop Mac has no battery: report as if on mains at full charge so
        // the battery guardrail can never fire there.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue()
                as? [String: Any]
        else {
            return PowerSnapshot(batteryPercent: 100, onACPower: true)
        }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 100
        let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return PowerSnapshot(batteryPercent: percent, onACPower: onAC)
    }
}
