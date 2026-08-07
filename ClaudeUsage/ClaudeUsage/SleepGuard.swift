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
    func removeHelper() async {
        if isOn { await disable(notifying: nil) }
        await client.unregister()
        refreshIdleState()
    }

    // MARK: Private

    private func enable() async {
        generation += 1
        let mine = generation
        let now = Date()
        enabledAt = now
        lastAssertionAt = now          // seeded: never restore immediately
        let failure = await client.setSleepDisabled(true, ttl: Int(leaseTTL))
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
    private func disable(notifying reason: SleepRestoreReason?) async {
        generation += 1
        let mine = generation
        timer?.invalidate()
        timer = nil
        let error = await client.setSleepDisabled(false, ttl: 0)
        // A later enable already released and retook the lease behind us; leave its
        // state alone. The daemon sees our release before that enable either way —
        // XPC keeps message order on a connection, and the daemon handles them on
        // one serial queue.
        guard mine == generation else { return }
        enabledAt = nil
        isOn = false
        if let error {
            uiState = .failed(error)
        } else {
            if let reason { ResetNotifier.notifySleepRestored(reason, capHours: capHours) }
            refreshIdleState()
        }
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
            let failure = await client.setSleepDisabled(true, ttl: Int(leaseTTL))
            // The user may have toggled off while the renewal was in flight. Stop
            // here rather than sending the re-assert sequence over their disable.
            guard mine == generation, isOn else { return }
            if let failure {
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
    private func reassertIfSettingLost() async -> String? {
        guard let state = await client.status() else { return nil }
        guard !state.disabled, state.secondsRemaining > 0 else { return nil }

        NSLog("claude-usage: SleepDisabled was cleared under a live lease; re-asserting")
        if let error = await client.setSleepDisabled(false, ttl: 0) { return error }
        if let error = await client.setSleepDisabled(true, ttl: Int(leaseTTL)) { return error }
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
