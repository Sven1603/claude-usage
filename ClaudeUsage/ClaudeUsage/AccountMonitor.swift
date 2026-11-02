import Foundation
import Combine
import ClaudeUsageCore

/// Polls usage for ONE account. `UsageModel` owns one of these per saved account,
/// so every account is tracked at the same time (not only the active one).
@MainActor
final class AccountMonitor: ObservableObject, Identifiable {
    let accountId: String
    nonisolated var id: String { accountId }

    @Published private(set) var state: UsageState = .waiting
    @Published private(set) var lastLimits: [UsageLimit] = []
    @Published private(set) var availableWorkspaces: [Workspace] = []
    @Published private(set) var trackedOrgUUID: String?
    /// Kind of the limit the menu bar shows ("session", or a weekly kind on plans
    /// without a session limit).
    @Published private(set) var headlineKind: String?
    @Published private(set) var headlineLabel: String?

    private let client = UsageClient()
    private var pollTimer: Timer?
    private var tickTimer: Timer?

    // Credentials are read from the Keychain once (at start and when this account's
    // key/org changes), then cached — the 1s poll never touches the Keychain.
    private var cachedKey: String?
    private var cachedOrg: String?

    // Last successful fetch snapshot (source of truth for the local tick).
    private var lastPercent: Int?
    private var lastSecondsToReset: Int?
    private var lastOrgName: String?
    private var lastSuccess: Date?
    private var authFailed = false
    private var isRefreshing = false
    /// Bumped when the workspace pin changes; a fetch started under an older
    /// generation is discarded when it lands (it describes the previous org).
    private var generation = 0
    private var lastFetchStarted: Date?
    // Reset-notification arming. Starts true so a monitor started while already
    // reset doesn't fire; set false once a live countdown (.ok) is seen.
    private var notifiedReset = true
    private var firedWarning = false
    private var firedCritical = false

    /// One-time name cache for pinned org UUIDs.
    private var pinnedOrgNameCache: [String: String] = [:]

    /// Poll interval — mirrors the LED device's 1s cadence.
    static let pollInterval: TimeInterval = 1
    /// Accounts not shown in the menu bar poll less often, so N accounts don't
    /// multiply the request rate (and risk 429s) N-fold.
    static let backgroundPollInterval: TimeInterval = 5

    init(accountId: String) {
        self.accountId = accountId
        cachedKey = AccountStore.shared.sessionKey(for: accountId)
        cachedOrg = AccountStore.shared.account(for: accountId)?.orgUUID
        recompute()
        Task { await self.refresh() }
        Task { await self.refreshWorkspaces() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollTick() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    /// Stop polling (account removed).
    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }

    var isSignedIn: Bool { !(cachedKey ?? "").isEmpty }

    /// Display name of this account (from the store; follows renames).
    var label: String { AccountStore.shared.account(for: accountId)?.label ?? "Claude account" }

    /// Called when the account store changed. Re-reads this account's credentials
    /// and, only if they actually changed, drops the snapshot so the next fetch is
    /// treated as a first fetch (another account being added/switched is a no-op).
    func reloadIfChanged() async {
        let org = AccountStore.shared.account(for: accountId)?.orgUUID
        guard org != cachedOrg else { return }
        // The session key of an existing account never changes (re-login adds a new
        // account), so only the pinned workspace needs watching.
        cachedOrg = org
        generation += 1
        pinnedOrgNameCache.removeAll()
        lastPercent = nil
        lastSecondsToReset = nil
        lastSuccess = nil
        lastOrgName = nil
        lastLimits = []
        headlineKind = nil
        headlineLabel = nil
        authFailed = false
        firedWarning = false
        firedCritical = false
        notifiedReset = true
        recompute()
        await refresh()   // if a fetch is in flight, pollTick picks this up within 1s
    }

    /// Timer entry: every tick for the menu-bar account, every few seconds for the rest.
    private func pollTick() async {
        let activeId = AccountStore.shared.activeId ?? AccountStore.shared.accounts.first?.id
        if activeId != accountId, let started = lastFetchStarted,
           Date().timeIntervalSince(started) < Self.backgroundPollInterval {
            return
        }
        await refresh()
    }

    /// Re-derive the displayed state from the last snapshot + current clock.
    func recompute() {
        let newState = deriveState(percent: lastPercent, secondsToReset: lastSecondsToReset,
                                   orgName: lastOrgName, lastSuccess: lastSuccess,
                                   now: Date(), authFailed: authFailed)
        if newState != state { state = newState }
        notifyOnResetTransition(newState)
    }

    /// Fire the reset notification the moment the countdown reaches 0. Armed only
    /// after an active countdown (`.ok`), fires at most once per reset.
    private func notifyOnResetTransition(_ state: UsageState) {
        switch state {
        case .ok:
            notifiedReset = false
        case .resetting:
            if !notifiedReset {
                notifiedReset = true
                if UserDefaults.standard.bool(forKey: "notifyOnReset") {
                    ResetNotifier.notifyReset(limitLabel: headlineLabel ?? "usage",
                                              account: accountNameForAlerts, accountId: accountId)
                }
            }
        default:
            break
        }
    }

    /// Account name to put in alerts — only when there is more than one account,
    /// so single-account users keep the old wording.
    private var accountNameForAlerts: String? {
        AccountStore.shared.accounts.count > 1 ? label : nil
    }

    /// Fire the warning/critical alert for the headline limit once per window.
    /// Re-arms whenever usage is below the warning threshold.
    private func maybeFireThresholdAlert(percent: Int, limitLabel: String) {
        guard UserDefaults.standard.bool(forKey: "notifyEnabled") else { return }
        let warning = threshold("warningThreshold", default: 75)
        let critical = threshold("criticalThreshold", default: 90)
        if percent < warning { firedWarning = false; firedCritical = false }
        guard let alert = pendingThresholdAlert(percent: percent, warning: warning, critical: critical,
                                                firedWarning: firedWarning, firedCritical: firedCritical)
        else { return }
        ResetNotifier.notifyThreshold(alert, percent: percent, limitLabel: limitLabel,
                                      account: accountNameForAlerts, accountId: accountId)
        switch alert {
        case .warning: firedWarning = true
        case .critical: firedWarning = true; firedCritical = true
        }
    }

    private func threshold(_ key: String, default def: Int) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)   // 0 = unset
        return v == 0 ? def : v
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let key = cachedKey, !key.isEmpty else {
            authFailed = false; lastSuccess = nil; recompute(); return
        }
        let gen = generation
        lastFetchStarted = Date()
        // Reflect a pinned workspace selection on the ✓ immediately.
        if let pinned = cachedOrg, !pinned.isEmpty, trackedOrgUUID != pinned { trackedOrgUUID = pinned }
        do {
            let r = try await client.resolve(sessionKey: key, pinnedOrg: cachedOrg, now: Date())
            guard gen == generation else { return }   // workspace changed mid-flight
            if r.limits != lastLimits { lastLimits = r.limits }
            if r.headline.kind != headlineKind || r.headline.label != headlineLabel {
                // A different limit is now the headline (plan change, or another
                // weekly limit became most-used): re-arm threshold alerts, and
                // disarm the reset alert until this limit shows a live countdown.
                firedWarning = false; firedCritical = false
                notifiedReset = true
                headlineKind = r.headline.kind
                headlineLabel = r.headline.label
            }
            lastPercent = r.headline.percent
            lastSecondsToReset = r.headline.secondsToReset
            maybeFireThresholdAlert(percent: r.headline.percent, limitLabel: r.headline.label)
            lastSuccess = Date()
            if trackedOrgUUID != r.org.uuid { trackedOrgUUID = r.org.uuid }
            authFailed = false
            if let name = r.org.name {
                lastOrgName = name
            } else {
                let name = await resolvedName(for: r.org.uuid, sessionKey: key)
                if gen == generation { lastOrgName = name }
            }
        } catch ClientError.auth {
            guard gen == generation else { return }
            authFailed = true
        } catch {
            // Keep last snapshot; it goes stale via deriveState.
        }
        recompute()
    }

    /// Fetch the chat workspaces this account can see (on start / workspace change).
    func refreshWorkspaces() async {
        guard let key = cachedKey, !key.isEmpty else { availableWorkspaces = []; return }
        if let orgs = try? await client.fetchOrgs(sessionKey: key) {
            availableWorkspaces = chatWorkspaces(from: orgs)
        }
    }

    /// Display name for a pinned org UUID (cached; falls back to the UUID prefix).
    private func resolvedName(for uuid: String, sessionKey: String) async -> String {
        if let cached = pinnedOrgNameCache[uuid] { return cached }
        let name: String
        if let orgs = try? await client.fetchOrgs(sessionKey: sessionKey) {
            name = orgs.first(where: { $0.uuid == uuid })?.name ?? String(uuid.prefix(8))
        } else {
            name = String(uuid.prefix(8))
        }
        pinnedOrgNameCache[uuid] = name
        return name
    }
}
