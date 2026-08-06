import Foundation
import IOKit.pwr_mgt

/// Who is currently holding the system awake.
public struct WakeAssertionSnapshot: Sendable, Equatable {
    public let holderCount: Int
    /// Unique, sorted process names, for showing the user why the Mac is awake.
    public let processNames: [String]

    public init(holderCount: Int, processNames: [String]) {
        self.holderCount = holderCount
        self.processNames = processNames
    }

    public var isAnythingHoldingWake: Bool { holderCount > 0 }
}

public protocol WakeAssertionReading: Sendable {
    func snapshot() -> WakeAssertionSnapshot
}

/// Human-readable holder list for the dropdown subtitle.
public func holderSummary(_ names: [String]) -> String {
    if names.isEmpty { return "nothing" }
    if names.count <= 3 { return names.joined(separator: ", ") }
    return "\(names[0]), \(names[1]) and \(names.count - 2) more"
}

/// Reads live assertions from IOKit. Unprivileged — no daemon round-trip needed.
public struct IOKitWakeAssertions: WakeAssertionReading {
    public init() {}

    public func snapshot() -> WakeAssertionSnapshot {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess, let out else {
            return WakeAssertionSnapshot(holderCount: 0, processNames: [])
        }
        guard let byProcess = out.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return WakeAssertionSnapshot(holderCount: 0, processNames: [])
        }

        let wanted: Set<String> = [
            kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            kIOPMAssertionTypeNoIdleSleep as String,
        ]

        var names: [String] = []
        for (_, assertions) in byProcess {
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String,
                      wanted.contains(type) else { continue }
                let name = assertion["Process Name"] as? String ?? "unknown"
                names.append(name)
            }
        }
        return WakeAssertionSnapshot(holderCount: names.count,
                                     processNames: Array(Set(names)).sorted())
    }
}
