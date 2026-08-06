import Foundation
import IOKit
import IOKit.pwr_mgt

/// The one place that reads boolean properties off `IOPMrootDomain`.
///
/// `Clamshell` and `SleepSetting` both need this, and both run as root. Getting
/// the IOKit ownership dance (`takeRetainedValue` plus `IOObjectRelease`) wrong
/// leaks or double-frees, so it is written once and audited once rather than
/// copied into two files.
enum PowerRootDomain {
    /// Reads a boolean property, or nil when the property is absent or is not a
    /// boolean. Absent is a real answer on some hardware, not an error, so the
    /// callers decide what nil means for them.
    static func flag(_ key: String) -> Bool? {
        let root = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        return IORegistryEntryCreateCFProperty(
            root, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}

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
    static func sleepNow() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { return }
        // IOPMLib.h: the handle from IOPMFindPowerManagement "must be released
        // with IOServiceClose() when done" — not IOObjectRelease.
        defer { IOServiceClose(port) }
        _ = IOPMSleepSystem(port)
    }
}
