import Foundation
import IOKit.ps

/// Whether the Mac is running on mains power.
///
/// The app already reads this through `IOKitPowerSource` in `ClaudeUsageCore`, but
/// the daemon deliberately does not link that target — doing so would drag the
/// usage client, networking and keychain code into a root binary and undo the
/// "auditable in one sitting" property. So the single bit the guardrail needs is
/// read here instead.
///
/// IOKit rather than parsing `pmset -g batt`: `SleepSetting.set` is the only place
/// this privileged binary spawns a subprocess, and that is a property worth keeping
/// true. `IOPSCopyPowerSourcesInfo` is public API and needs no privileges.
enum DaemonPower {
    /// True when on mains, and true when the answer cannot be determined.
    ///
    /// The caller only uses this to *suppress* a forced sleep, so an unknown power
    /// state leaves the machine alone rather than sleeping it on a guess. A Mac with
    /// no power source at all is a desktop: on mains by definition, and it has no
    /// lid either, so that branch can never reach a forced sleep anyway. This
    /// matches `IOKitPowerSource`'s own fallback in the app.
    static func isOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue()
                as? [String: Any]
        else {
            return true
        }
        return (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
    }
}
