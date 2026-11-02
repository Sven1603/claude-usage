import Foundation
import IOKit

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
