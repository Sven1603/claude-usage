import Foundation

/// Mach service the daemon listens on. Must match the plist's MachServices key
/// and the daemon's Label.
let sleeperMachServiceName = "com.sven.claude-usage.sleeperd"

/// Only the shipped, correctly-signed app may drive the daemon. Without this any
/// local process could disable sleep. Applied to the *listener* in the daemon's
/// `main.swift` with NSXPCListener.setConnectionCodeSigningRequirement(_:) —
/// public API since macOS 13, which matches the deployment target — so a peer
/// that does not match is rejected before the listener delegate is consulted.
/// (The per-connection NSXPCConnection.setCodeSigningRequirement(_:) is the
/// alternative, but it reports a mismatch by invalidating the connection later
/// rather than by refusing it, so the delegate has nothing to act on.)
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
    ///
    /// `sleepIfLidClosed` distinguishes the two kinds of restore the design calls
    /// for, and is ignored when `disabled` is true. False is a user toggle-off:
    /// give the setting back and leave a Mac whose owner is sitting in front of it
    /// alone. True is a guardrail — cap reached, battery low, nothing running —
    /// where restoring `SleepDisabled` to 0 with the lid already shut may not sleep
    /// the machine on its own, so the daemon sleeps it explicitly. Without this
    /// parameter every app-driven guardrail would read as a toggle-off and a Mac in
    /// a bag would keep draining, which is what the battery argument rests on.
    func setSleepDisabled(_ disabled: Bool,
                          ttl: Int,
                          sleepIfLidClosed: Bool,
                          reply: @escaping (Bool, String?) -> Void)

    /// Current state. Reply is (sleepIsDisabled, secondsRemainingOnLease).
    func status(reply: @escaping (Bool, Int) -> Void)
}
