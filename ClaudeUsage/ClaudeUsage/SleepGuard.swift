import Foundation
import Combine
import ClaudeUsageCore
import SleepLease

/// Owns the keep-awake feature: holds the lease while the policy says to, and
/// gives it back the moment a guardrail trips.
@MainActor
final class SleepGuard: ObservableObject {
    @Published private(set) var uiState: KeepAwakeUIState = .off
    @Published private(set) var isOn = false

    private let client = PrivilegedClient()
    private let assertions: WakeAssertionReading
    private let power: PowerSourceReading

    private var timer: Timer?
    private var enabledAt: Date?
    private var lastAssertionAt: Date?
    /// A tick makes up to four XPC round trips, each of which the daemon bounds at
    /// a few seconds, so a bad one can outlast the 15s timer. Without this the next
    /// fire would interleave a second enable/disable sequence with the first.
    private var isTicking = false
    /// Bumped by every enable and disable. `@MainActor` serialises the writes but
    /// not the awaits between them, so two quick toggles can overlap: whoever
    /// resumes and finds this changed was superseded, and must neither write its
    /// result over the newer one nor keep sending XPC about a lease it no longer
    /// owns. Losing that race the other way leaves `isOn` true with a live renewal
    /// timer after the user asked for off, which is the one outcome this feature
    /// must not have.
    private var generation = 0

    init(assertions: WakeAssertionReading = IOKitWakeAssertions(),
         power: PowerSourceReading = IOKitPowerSource()) {
        self.assertions = assertions
        self.power = power
        refreshIdleState()
        Task { await releaseLeaseFromAPreviousRun() }
    }

    var cap: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "keepAwakeCapSeconds")
        return stored == 0 ? sleepCapDefault : stored
    }
    var capHours: Int { Int(cap / 3600) }

    /// Hits `SMAppService.status`, so it is only read on user-driven paths (the
    /// toggle, and settling into an idle state) — never on the 15s tick. That keeps
    /// it a handful of calls per session, which is not worth a cache that could go
    /// stale against approvals the user makes in System Settings behind our back.
    var needsSetup: Bool { client.registration != .enabled }

    func openLoginItemsSettings() { client.openLoginItemsSettings() }

    /// First-run path: register the daemon, then turn on if that worked.
    func setUpAndEnable() async {
        switch await client.register() {
        case .enabled:
            await enable()
        case .requiresApproval:
            uiState = .failed("Approve Claude Usage in Login Items, then try again.")
            client.openLoginItemsSettings()
        case .notRegistered:
            uiState = .failed("The sleep helper did not install.")
        case let .failed(message):
            uiState = .failed(message)
        }
    }

    func toggle(_ on: Bool) async {
        if on {
            if needsSetup { await setUpAndEnable() } else { await enable() }
        } else {
            await disable(notifying: nil)
        }
    }

    /// Turn the feature off first, then tear down the helper — never leave a
    /// disabled-sleep setting behind with no privileged way to undo it.
    ///
    /// The release is unconditional rather than gated on `isOn`, because the
    /// dangerous case is exactly the one where the two disagree: a failed renewal or
    /// a lease left over from a previous run means the daemon holds a claim while
    /// this app believes the feature is off. The daemon no-ops when it holds neither
    /// a lease nor a marker, so an unconditional call costs nothing in the common
    /// case.
    ///
    /// And if the release fails, the helper stays. Unregistering here would destroy
    /// the lease lapse that `disable` relies on to put sleep back — no daemon means
    /// no expiry timer, and `RunAtLoad` cannot self-heal a service that is no longer
    /// registered.
    ///
    /// A failure only blocks the removal when the helper is actually enabled. In any
    /// other state launchd is not running our daemon, so it cannot be holding a
    /// claim — a helper switched off in System Settings was SIGTERMed, and the
    /// daemon restores sleep on that path. Refusing to remove a helper that is
    /// already gone would just be a dead end.
    func removeHelper() async {
        let wasEnabled = client.registration == .enabled
        if let error = await disable(notifying: nil), wasEnabled {
            uiState = .failed("Sleep could not be restored, so the helper was kept: \(error)")
            return
        }
        await client.unregister()
        refreshIdleState()
    }

    // MARK: Private

    /// A relaunch inside the previous run's lease window finds the daemon still
    /// holding it, with up to `leaseTTL` to run. Nothing else reconciles that: the
    /// row would read "Your Mac sleeps normally when you close the lid" and the moon
    /// glyph would be absent, for up to 90 seconds during which sleep is in fact
    /// disabled.
    ///
    /// Release rather than adopt. Adopting would mean reconstructing `enabledAt`
    /// from the daemon's remaining seconds, and getting that wrong silently restarts
    /// the 4h cap — the number the whole battery argument rests on. Releasing makes
    /// the "off" already on screen immediately true, cannot double-own the lease,
    /// and leaves the user one toggle away from where they were.
    ///
    /// Registration is checked first so the overwhelming majority of launches, by
    /// users who never enabled the feature, do not open an XPC connection at all.
    private func releaseLeaseFromAPreviousRun() async {
        guard client.registration == .enabled else { return }
        guard let state = await client.status(), state.secondsRemaining > 0 else { return }
        // The user reached the toggle before the daemon answered. Their intent wins,
        // and `enable` has taken the lease over already.
        guard generation == 0 else { return }
        await disable(notifying: nil)
    }

    private func enable() async {
        generation += 1
        let mine = generation
        let now = Date()
        enabledAt = now
        lastAssertionAt = now          // seeded: never restore immediately
        let failure = await client.setSleepDisabled(true, ttl: Int(leaseTTL),
                                                    sleepIfLidClosed: false)
        guard mine == generation else { return }   // superseded while we waited
        if let failure {
            enabledAt = nil
            isOn = false
            uiState = .failed(failure)
            return
        }
        isOn = true
        startTimer()
        refreshUIState(now: now, assertion: assertions.snapshot(), power: power.snapshot())
    }

    /// Gives the lease back. `isOn` ends false either way, including when the
    /// helper reports a failure: we stop renewing at that point, so the daemon's
    /// lease lapses within `leaseTTL` and it restores sleep by itself. An off
    /// toggle with the failure text underneath it is therefore the honest reading —
    /// we are no longer keeping the Mac awake, and something needs the user's
    /// attention.
    ///
    /// `reason` does double duty. It names the guardrail for the notification, and
    /// its presence is what tells the daemon this is a guardrail rather than a user
    /// toggling off — which is what makes it sleep a Mac whose lid is already shut.
    /// A user sitting in front of an open machine and switching this off must never
    /// have it slept underneath them, so a nil reason never forces sleep.
    ///
    /// Returns nil once sleep is genuinely back with the daemon, else a message.
    /// `removeHelper` reads this: unregistering after a failed release would remove
    /// the only thing that could still put sleep back.
    @discardableResult
    private func disable(notifying reason: SleepRestoreReason?) async -> String? {
        generation += 1
        let mine = generation
        timer?.invalidate()
        timer = nil
        let error = await client.setSleepDisabled(false, ttl: 0,
                                                  sleepIfLidClosed: reason != nil)
        // A later enable already released and retook the lease behind us; leave its
        // state alone. The daemon sees our release before that enable either way —
        // XPC keeps message order on a connection, and the daemon handles them on
        // one serial queue. Reported as a failure rather than nil, because sleep is
        // demonstrably not restored: something re-took the lease.
        guard mine == generation else {
            return "Keep awake was switched on again while sleep was being restored."
        }
        enabledAt = nil
        isOn = false
        if let error {
            uiState = .failed(error)
            return error
        }
        if let reason { ResetNotifier.notifySleepRestored(reason, capHours: capHours) }
        refreshIdleState()
        return nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: leaseRenewInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    /// One pass: sample the world, decide, then either renew the lease or give it back.
    private func tick() async {
        guard isOn, let enabledAt, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        let mine = generation

        let now = Date()
        let assertion = assertions.snapshot()
        if assertion.isAnythingHoldingWake { lastAssertionAt = now }

        let powerSnapshot = power.snapshot()
        let world = SleepWorld(now: now,
                               enabledAt: enabledAt,
                               cap: cap,
                               lastAssertionAt: lastAssertionAt ?? enabledAt,
                               batteryPercent: powerSnapshot.batteryPercent,
                               onACPower: powerSnapshot.onACPower)

        switch decideSleep(world) {
        case .keepAwake:
            let failure = await client.setSleepDisabled(true, ttl: Int(leaseTTL),
                                                        sleepIfLidClosed: false)
            // The user may have toggled off while the renewal was in flight. Stop
            // here rather than sending the re-assert sequence over their disable.
            guard mine == generation, isOn else { return }
            if let failure {
                // Stop, rather than leaving the toggle on with a live timer. The
                // daemon's lease lapses within `leaseTTL` and sleep comes back with
                // or without us, so a moon glyph still showing after this is a
                // promise we cannot keep — and a user who closes the lid trusting it
                // loses the session. Matches `disable`'s invariant: no renewal in
                // flight means the toggle is off.
                self.enabledAt = nil   // shadowed by the guard at the top of tick()
                isOn = false
                timer?.invalidate()
                timer = nil
                uiState = .failed(failure)
                return
            }
            let lostSetting = await reassertIfSettingLost()
            guard mine == generation, isOn else { return }
            if let lostSetting {
                // We renewed a lease over a setting we could not get back. Stop
                // pretending: give the lease up and say what happened.
                await disable(notifying: nil)
                uiState = .failed(lostSetting)
                return
            }
            refreshUIState(now: now, assertion: assertion, power: powerSnapshot)
        case let .restore(reason):
            await disable(notifying: reason)
        }
    }

    /// Second daemon contract: `status()` reports the live system setting and the
    /// daemon's own lease bookkeeping separately, and they can disagree. `disabled
    /// == false` with time still on the lease means something outside this app
    /// cleared `SleepDisabled` while we believed we held it — the Mac is no longer
    /// being kept awake even though the daemon thinks it is. (The mirror case,
    /// inferring ownership from `disabled == true`, is never done: that is also true
    /// for the user's own setting, and only the daemon's marker knows the
    /// difference.)
    ///
    /// Re-asserting is a release followed by a fresh acquisition rather than a
    /// second `true`: the daemon only writes the setting when it holds no lease, so
    /// renewing over a live one would report success without touching `pmset`.
    ///
    /// Returns nil when the setting is (or is now) in place, else a message. A
    /// helper that cannot be reached returns nil too — the renewal immediately
    /// before this has already succeeded, so an unreachable helper here says
    /// nothing new and is not worth a second error path.
    ///
    /// Every step re-checks `generation`, and the check before the re-acquire is the
    /// load-bearing one. A user toggle-off landing between the release and the
    /// re-acquire would otherwise be followed by us disabling sleep again for a
    /// whole `leaseTTL` *after* they asked for off, and racing `removeHelper` that
    /// leaves a lease behind with no daemon to lapse it. Checking immediately before
    /// each send is enough: both run on the main actor without an intervening
    /// suspension, so nothing can bump `generation` between the guard and the
    /// message going out.
    private func reassertIfSettingLost() async -> String? {
        let mine = generation
        guard let state = await client.status() else { return nil }
        guard !state.disabled, state.secondsRemaining > 0 else { return nil }
        guard mine == generation, isOn else { return nil }

        NSLog("claude-usage: SleepDisabled was cleared under a live lease; re-asserting")
        if let error = await client.setSleepDisabled(false, ttl: 0,
                                                     sleepIfLidClosed: false) { return error }
        guard mine == generation, isOn else { return nil }
        if let error = await client.setSleepDisabled(true, ttl: Int(leaseTTL),
                                                     sleepIfLidClosed: false) { return error }
        guard mine == generation, isOn else { return nil }
        if let after = await client.status(), !after.disabled {
            return "Something else re-enabled sleep. Turn keep awake off and on to retry."
        }
        return nil
    }

    /// Renders the state from snapshots the caller already took — one IOKit round
    /// trip per source per tick, not two.
    private func refreshUIState(now: Date,
                                assertion: WakeAssertionSnapshot,
                                power powerSnapshot: PowerSnapshot) {
        guard isOn, let enabledAt else { refreshIdleState(); return }

        if !assertion.isAnythingHoldingWake, let lastAssertionAt {
            // Clamped: the policy fires at the grace period, but this renders from
            // the same instant, and any rounding or a late tick would otherwise show
            // "sleeping in -3s" for the moment before the restore lands.
            let idleFor = now.timeIntervalSince(lastAssertionAt)
            let left = Int((sleepGracePeriod - idleFor).rounded(.down))
            uiState = .grace(secondsUntilSleep: max(0, left))
            return
        }
        let left = Int(cap - now.timeIntervalSince(enabledAt))
        uiState = .active(holders: assertion.processNames,
                          secondsLeft: max(0, left),
                          batteryPercent: powerSnapshot.batteryPercent,
                          onAC: powerSnapshot.onACPower)
    }

    private func refreshIdleState() {
        uiState = needsSetup ? .needsSetup : .off
    }
}
