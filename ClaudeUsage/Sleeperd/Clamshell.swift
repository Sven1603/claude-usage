import Foundation
import IOKit
import IOKit.pwr_mgt
import os

private let log = Logger(subsystem: "com.sven.claude-usage.sleeperd", category: "Clamshell")

/// Lid state, and the ability to sleep the machine on purpose.
///
/// Restoring `SleepDisabled` to 0 while the lid is already shut may not sleep the
/// Mac on its own — the behaviour is undocumented and could wait for the next lid
/// event, which would make every guardrail useless in exactly the case they exist
/// for. So a guardrail restore with the lid shut sleeps the machine explicitly.
enum Clamshell {
    /// True when the lid is closed.
    ///
    /// A Mac without a lid has no `AppleClamshellState` property at all, and its
    /// lid is never shut, so a missing property reads as open.
    static func isClosed() -> Bool {
        PowerRootDomain.flag("AppleClamshellState") ?? false
    }

    /// Ask the system to sleep now. Root or console user only.
    ///
    /// This is the guardrail's last action, so a silent failure here is the
    /// difference between a Mac that sleeps and one that stays awake in a bag. It
    /// cannot report back to the app — the guardrail fires on the daemon's own
    /// timer, with no request in flight — so failures are logged instead.
    static func sleepNow() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else {
            log.error("IOPMFindPowerManagement returned no port; cannot sleep the system")
            return
        }
        // IOPMLib.h: the handle from IOPMFindPowerManagement "must be released
        // with IOServiceClose() when done" — not IOObjectRelease.
        defer { IOServiceClose(port) }

        let result = IOPMSleepSystem(port)
        if result != kIOReturnSuccess {
            log.error("IOPMSleepSystem failed: \(String(format: "0x%08x", result), privacy: .public)")
        }
    }
}
