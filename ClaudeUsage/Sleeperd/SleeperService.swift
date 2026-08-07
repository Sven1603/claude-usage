import Foundation
import os
import Security
import SleepLease

private let log = Logger(subsystem: "com.sven.claude-usage.sleeperd", category: "SleeperService")

/// Implements the XPC contract. Every decision about *whether* to stay awake is
/// made by the app; this only holds the lease and flips the setting.
final class SleeperService: NSObject, SleeperProtocol {
    private let queue = DispatchQueue(label: "com.sven.claude-usage.sleeperd.state")
    private var lease: Lease?
    private var timer: DispatchSourceTimer?
    /// SleepDisabled was already 1 before we ever touched it, i.e. the user's own
    /// setting. Recorded once per lease acquisition, and it makes every restore a
    /// no-op.
    private var sleepWasAlreadyDisabled = false

    func setSleepDisabled(_ disabled: Bool, ttl: Int, sleepIfLidClosed: Bool,
                          reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            if disabled {
                if self.lease == nil {
                    self.sleepWasAlreadyDisabled = self.existingOwnership()
                    // Marker BEFORE the write, honouring LeaseMarker's own documented
                    // contract. If pmset applies the setting but we die, or the
                    // read-back spuriously disagrees, a marker-last ordering would
                    // leave sleep disabled with nothing on disk to restore it — and
                    // SleepDisabled survives reboots. A stale marker after a genuine
                    // pmset failure only makes the next daemon start run
                    // `pmset -a disablesleep 0` against a setting already at 0.
                    guard MarkerStore.write(LeaseMarker(
                            ownedByUs: true,
                            sleepWasAlreadyDisabled: self.sleepWasAlreadyDisabled,
                            setAt: Date())) else {
                        reply(false, "Could not record the sleep marker, so sleep was left alone.")
                        return
                    }
                    if let error = SleepSetting.set(disabled: true) {
                        // Deliberately do NOT clear the marker here: pmset may have
                        // applied the setting even though we could not confirm it.
                        log.error("Could not disable sleep: \(error, privacy: .public)")
                        reply(false, error)
                        return
                    }
                    log.notice("""
                        Sleep disabled on a \(ttl, privacy: .public)s lease \
                        (user had it disabled already: \
                        \(self.sleepWasAlreadyDisabled, privacy: .public))
                        """)
                }
                self.lease = Lease.starting(at: Date(), ttl: TimeInterval(ttl))
                self.scheduleExpiry()
                reply(true, nil)
            } else {
                // No lease in memory and no marker on disk means we hold no claim and
                // never disabled anything, so there is nothing to give back. Without
                // this, an app that calls toggle-off defensively at launch would run
                // `pmset -a disablesleep 0` over a value the user set themselves.
                if self.lease == nil, case .absent = MarkerStore.read() {
                    reply(true, nil)
                    return
                }
                // The app says which kind of restore this is. A user toggle-off
                // never forces sleep on a Mac whose owner is sitting in front of
                // it; an app-driven guardrail does, for the same reason the
                // lease-expiry path does.
                let error = self.restore(forceSleepIfLidClosed: sleepIfLidClosed)
                reply(error == nil, error)
            }
        }
    }

    func status(reply: @escaping (Bool, Int) -> Void) {
        queue.async {
            let remaining = self.lease?.secondsRemaining(at: Date()) ?? 0
            // The first value is real system state and the second is our own claim,
            // so they can legitimately disagree — sleep disabled with no lease is the
            // user's own setting, and no sleep disabled with a live lease means we
            // lost the setting to something else. The app is the one that can tell
            // those apart, so both are reported as they are rather than reconciled
            // here.
            reply(SleepSetting.isDisabled(), remaining)
        }
    }

    /// Called once at daemon start, before the listener accepts anything. A marker
    /// here means the app died mid-lease.
    ///
    /// Synchronous on purpose: this must be finished before we serve a single
    /// request, and before any path that could exit the process, rather than merely
    /// enqueued ahead of them.
    ///
    /// A marker that exists but will not decode restores sleep rather than being
    /// ignored. The two failure modes are asymmetric: wrongly undoing a user's own
    /// `sudo pmset disablesleep 1` is visible and they can redo it, whereas wrongly
    /// leaving sleep disabled is invisible and permanent. A file at our path also
    /// strongly implies we wrote it.
    func restoreIfOrphaned() {
        queue.sync {
            switch MarkerStore.read() {
            case .absent:
                return
            case .corrupt:
                log.error("Marker present but unreadable at start; restoring sleep anyway")
                self.forceRestoreAtStart()
            case let .present(marker):
                guard shouldRestoreOnBoot(marker: marker) else {
                    // The value is the user's own: drop our stale marker but leave
                    // their setting alone.
                    log.notice("Stale marker for the user's own SleepDisabled; clearing it only")
                    MarkerStore.clear()
                    return
                }
                log.notice("Orphaned lease from \(marker.setAt, privacy: .public); restoring sleep")
                self.forceRestoreAtStart()
            }
        }
    }

    /// Called from the SIGTERM handler in `main.swift`, on the way out.
    ///
    /// Every orderly teardown of this daemon is a SIGTERM: `SMAppService.unregister`
    /// from "Remove helper", the user switching the item off in System Settings, and
    /// the cask's `uninstall launchctl:` directive. Without this the process dies
    /// with `SleepDisabled` at 1, the marker on disk and the expiry timer gone —
    /// and because the daemon is no longer registered, `RunAtLoad` never fires
    /// again, not even after a reboot. `SleepDisabled` lives in
    /// `com.apple.PowerManagement.plist` and survives one, so the user would be left
    /// with a Mac that never sleeps and, if the app bundle is gone too, no remedy
    /// short of `sudo pmset -a disablesleep 0`.
    ///
    /// Synchronous on `queue`, so it cannot interleave with an XPC call already in
    /// flight. launchd's default 20s `ExitTimeOut` comfortably covers the 5s `pmset`
    /// watchdog underneath this.
    ///
    /// Never forces sleep: a teardown is a deliberate act by someone at the machine,
    /// which is the toggle-off reading, not the guardrail one.
    func restoreOnTeardown() {
        queue.sync {
            // Same no-op as the toggle-off path: no lease and no marker means we
            // hold no claim, so there is nothing to give back and nothing to stomp.
            if self.lease == nil, case .absent = MarkerStore.read() { return }
            log.notice("Received SIGTERM while holding a claim; restoring sleep before exit")
            _ = self.restore(forceSleepIfLidClosed: false)
        }
    }

    // MARK: Private

    /// Restores sleep on the boot/self-heal path and drops the marker.
    ///
    /// The marker is cleared even when the write failed, unlike `restore`: at start
    /// there is no lease and no app waiting on a reply, so a marker kept here would
    /// be retried only at the next daemon start, which may be the next reboot. The
    /// failure is logged as a fault because it is the one state the design cannot
    /// recover from on its own.
    private func forceRestoreAtStart() {
        if let error = SleepSetting.set(disabled: false) {
            log.fault("Could not restore sleep at start: \(error, privacy: .public)")
            return
        }
        MarkerStore.clear()
    }

    /// Whether SleepDisabled being 1 right now is the user's own setting rather than
    /// ours. Must be called on `queue`, and only when no lease is held.
    ///
    /// A marker still on disk at this point means an earlier restore failed or never
    /// ran, so the current value is ours. Reading the live setting instead would
    /// record `sleepWasAlreadyDisabled = true`, which makes every later restore a
    /// no-op and `shouldRestoreOnBoot` false — sleep disabled forever, the one state
    /// this design must never reach.
    private func existingOwnership() -> Bool {
        switch MarkerStore.read() {
        case .absent:
            return SleepSetting.isDisabled()
        case .corrupt:
            // Same asymmetry as `restoreIfOrphaned`: a file at our path is almost
            // certainly ours, and claiming ownership we do not have costs the user a
            // setting they can redo, while disclaiming ownership we do have costs
            // them a Mac that never sleeps.
            return false
        case let .present(marker):
            return marker.sleepWasAlreadyDisabled
        }
    }

    /// Must be called on `queue`.
    private func scheduleExpiry() {
        timer?.cancel()
        guard let lease else { timer = nil; return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Floored seconds plus one, so the deadline is strictly after `expiresAt` and
        // the handler below normally finds the lease already expired. The re-arm
        // there is for a wall clock that moved backwards under us: the deadline is
        // monotonic, `expiresAt` is not.
        t.schedule(deadline: .now() + .seconds(lease.secondsRemaining(at: Date()) + 1))
        t.setEventHandler { [weak self] in
            guard let self, let lease = self.lease else { return }
            guard lease.isExpired(at: Date()) else { self.scheduleExpiry(); return }
            // The app stopped renewing: crash, force-quit, logout, or a guardrail
            // it could not report. Sleep the Mac if the lid is already shut.
            log.notice("Lease lapsed without a renewal; restoring sleep")
            _ = self.restore(forceSleepIfLidClosed: true)
        }
        t.resume()
        timer = t
    }

    /// Must be called on `queue`. Returns nil on success, else a message.
    ///
    /// The lease and its timer are dropped before the write is attempted. A lease
    /// must never outlive the decision to end it: keeping it would make `status`
    /// report time remaining while we are actively trying to give the setting back,
    /// which is the misleading direction. Durable recovery lives in the marker
    /// instead — it stays on disk when the write fails, so the app's next call or the
    /// next daemon start restores sleep, and that survives a reboot in a way
    /// in-memory state does not.
    @discardableResult
    private func restore(forceSleepIfLidClosed: Bool) -> String? {
        timer?.cancel()
        timer = nil
        lease = nil

        guard !sleepWasAlreadyDisabled else {
            // The user set SleepDisabled themselves before we arrived. Give up our
            // claim without changing their setting.
            MarkerStore.clear()
            return nil
        }

        if let error = SleepSetting.set(disabled: false) {
            log.error("Could not restore sleep: \(error, privacy: .public)")
            return error
        }
        MarkerStore.clear()

        // Only on battery. A shut lid on mains is very often clamshell mode with an
        // external display — a normal, fully-awake configuration that the design
        // lists as a non-goal, and slamming it to sleep mid-work would be worse than
        // the drain this guardrail exists to prevent. On mains the setting is simply
        // handed back and macOS's own idle policy decides. The battery argument is
        // untouched: it is about a Mac awake in a bag, which is a Mac on battery.
        if forceSleepIfLidClosed && Clamshell.isClosed() && !DaemonPower.isOnACPower() {
            log.notice("Lid is shut on battery for a guardrail restore; sleeping the system")
            Clamshell.sleepNow()
        }
        return nil
    }
}

/// Wires up connections from the app.
///
/// The code-signing gate is *not* here: it is applied to the listener itself in
/// `main.swift`, which rejects a peer that does not match before this delegate is
/// consulted, so an unverified process never gets our exported object attached.
/// `NSXPCConnection.setCodeSigningRequirement` is the per-connection alternative,
/// but it is non-throwing and reports a mismatch by invalidating the connection
/// later, so a delegate cannot see a rejection to act on or log.
final class SleeperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: SleeperService
    /// False when `sleeperClientRequirement` will not parse, in which case no
    /// connection is served at all. See `validateClientRequirement`.
    private let requirementIsUsable: Bool

    init(service: SleeperService, requirementIsUsable: Bool) {
        self.service = service
        self.requirementIsUsable = requirementIsUsable
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard requirementIsUsable else {
            log.fault("""
                Rejected connection from pid \(connection.processIdentifier, privacy: .public): \
                the client code-signing requirement does not parse, so no client can be trusted
                """)
            return false
        }
        log.notice("""
            Accepted connection from pid \(connection.processIdentifier, privacy: .public), \
            uid \(connection.effectiveUserIdentifier, privacy: .public)
            """)
        connection.exportedInterface = NSXPCInterface(with: SleeperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

/// Checks that `sleeperClientRequirement` parses, because
/// `setConnectionCodeSigningRequirement` raises an Objective-C exception on a
/// malformed requirement, and that is not catchable from Swift.
///
/// A typo in the constant would therefore take down a root daemon on every
/// connection attempt. Parsing it first turns that into a logged refusal to serve,
/// which fails closed in the same direction without the crash loop.
func validateClientRequirement() -> Bool {
    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString(
        sleeperClientRequirement as CFString, [], &requirement)
    guard status == errSecSuccess, requirement != nil else {
        log.fault("""
            Client code-signing requirement does not parse (OSStatus \
            \(status, privacy: .public)); refusing to serve any connection
            """)
        return false
    }
    return true
}
