import Foundation
import Combine
import ClaudeUsageCore

extension Notification.Name {
    /// Posted by Settings after saving; tells the model to re-read the Keychain.
    static let claudeCredentialsChanged = Notification.Name("claudeCredentialsChanged")
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var state: UsageState = .waiting
    @Published private(set) var lastLimits: [UsageLimit] = []

    private let client = UsageClient()
    private var pollTimer: Timer?
    private var tickTimer: Timer?

    // Credentials are read from the Keychain once (at launch and whenever Settings
    // saves), then cached here — so the 1s poll never touches the Keychain and
    // doesn't trigger repeated access prompts.
    private var cachedKey: String?
    private var cachedOrg: String?

    // Last successful fetch snapshot (source of truth for the local tick).
    private var lastPercent: Int?
    private var lastSecondsToReset: Int?
    private var lastOrgName: String?
    private var lastSuccess: Date?
    private var authFailed = false
    private var isRefreshing = false
    // Reset-notification arming. Starts true so an app launched while already
    // reset doesn't fire; set false once a live countdown (.ok) is seen.
    private var notifiedReset = true

    /// One-time name cache for pinned org UUIDs.
    /// Keyed by UUID; value is the resolved name (or UUID prefix if lookup fails).
    private var pinnedOrgNameCache: [String: String] = [:]

    /// Poll interval — mirrors the LED device's 1s cadence (single constant).
    let pollInterval: TimeInterval = 1
    private var started = false

    init() { start() }

    /// Idempotent: called once from init when the model is created.
    func start() {
        guard !started else { return }
        started = true
        loadCredentials()
        recompute()
        Task { await self.refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        // Re-read the Keychain (once) when the user saves new credentials.
        NotificationCenter.default.addObserver(
            forName: .claudeCredentialsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.loadCredentials()
                self?.pinnedOrgNameCache.removeAll()
                // Credentials changed (e.g. signed into a different account): drop the
                // last snapshot so the next fetch is treated as a first fetch and can't
                // fire a spurious "limit reset" notification off a stale countdown.
                self?.lastPercent = nil
                self?.lastSecondsToReset = nil
                self?.lastSuccess = nil
                await self?.refresh()
            }
        }
    }

    /// Whether a session key is currently stored (from the cached value — no
    /// Keychain read). Valid immediately after init since `start()` loads it.
    var isSignedIn: Bool { !(cachedKey ?? "").isEmpty }

    /// Read credentials from the Keychain into the in-memory cache (one read each).
    private func loadCredentials() {
        cachedKey = Keychain.sessionKey
        cachedOrg = Keychain.orgUUID
    }

    /// Re-derive the displayed state from the last snapshot + current clock.
    /// Runs every second (tick) as well as after each fetch.
    func recompute() {
        let newState = deriveState(percent: lastPercent, secondsToReset: lastSecondsToReset,
                                   orgName: lastOrgName, lastSuccess: lastSuccess,
                                   now: Date(), authFailed: authFailed)
        state = newState
        notifyOnResetTransition(newState)
    }

    /// Fire the reset notification the moment the countdown reaches 0 — i.e. when
    /// the state ticks into `.resetting` — rather than when a new window is later
    /// detected. Armed only after an active countdown (`.ok`) so it never fires
    /// spuriously at launch, and fires at most once per reset.
    private func notifyOnResetTransition(_ state: UsageState) {
        switch state {
        case .ok:
            notifiedReset = false            // arm for the next reset
        case .resetting:
            if !notifiedReset {
                notifiedReset = true
                if UserDefaults.standard.bool(forKey: "notifyOnReset") {
                    ResetNotifier.notifyReset()
                }
            }
        default:
            break                            // waiting / stale / authError: no change
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let key = cachedKey, !key.isEmpty else {
            authFailed = false; lastSuccess = nil; recompute(); return
        }
        do {
            let (session, org, limits) = try await client.resolve(
                sessionKey: key, pinnedOrg: cachedOrg, now: Date())
            lastLimits = limits
            lastPercent = session.percent
            lastSecondsToReset = session.secondsToReset
            lastSuccess = Date()
            authFailed = false

            // Determine the displayed org name.
            if let name = org.name {
                // Auto-detect path already supplies the name.
                lastOrgName = name
            } else {
                // Pinned-org path: resolve the name once and cache it.
                lastOrgName = await resolvedName(for: org.uuid, sessionKey: key)
            }
        } catch ClientError.auth {
            authFailed = true
        } catch {
            // Keep last snapshot; it will go stale via deriveState. Network hiccup.
        }
        recompute()
    }

    /// Returns a display name for the given org UUID.
    /// Uses the cache when available; otherwise fetches the org list once.
    /// If the fetch fails, falls back to the first 8 characters of the UUID.
    /// Never throws — the usage data path must stay independent of this lookup.
    private func resolvedName(for uuid: String, sessionKey: String) async -> String {
        if let cached = pinnedOrgNameCache[uuid] { return cached }
        let name: String
        do {
            let orgs = try await client.fetchOrgs(sessionKey: sessionKey)
            name = orgs.first(where: { $0.uuid == uuid })?.name ?? String(uuid.prefix(8))
        } catch {
            // Lookup failed (network, auth, etc.) — use UUID prefix as fallback.
            name = String(uuid.prefix(8))
        }
        pinnedOrgNameCache[uuid] = name
        return name
    }
}
