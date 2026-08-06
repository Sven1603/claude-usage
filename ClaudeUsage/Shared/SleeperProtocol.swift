import Foundation

/// Mach service the daemon listens on. Must match the plist's MachServices key
/// and the daemon's Label.
let sleeperMachServiceName = "com.sven.claude-usage.sleeperd"

/// Only the shipped, correctly-signed app may drive the daemon. Without this any
/// local process could disable sleep. Applied with
/// NSXPCConnection.setCodeSigningRequirement(_:) — public API since macOS 13,
/// which matches the deployment target.
///
/// The team identifier is hardcoded. If the signing identity ever changes, this
/// string and project.yml must change together, or the app silently loses the
/// ability to talk to its own helper.
let sleeperClientRequirement =
    "anchor apple generic and identifier \"com.sven.claude-usage\" "
    + "and certificate leaf[subject.OU] = \"H9PBNT2Q88\""

/// The entire privileged surface: one setter and one getter.
///
/// Deliberately minimal. The daemon makes no decisions — the app decides whether
/// to keep the Mac awake and the daemon only flips the setting, so the code
/// running as root stays small enough to audit in one sitting.
@objc protocol SleeperProtocol {
    /// Disable or restore system sleep. When disabling, `ttl` seconds is a lease:
    /// the daemon restores sleep by itself once it lapses unless the app renews.
    /// Reply is (ok, errorMessage).
    func setSleepDisabled(_ disabled: Bool,
                          ttl: Int,
                          reply: @escaping (Bool, String?) -> Void)

    /// Current state. Reply is (sleepIsDisabled, secondsRemainingOnLease).
    func status(reply: @escaping (Bool, Int) -> Void)
}
