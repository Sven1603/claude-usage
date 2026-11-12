import Foundation
import Combine
import ClaudeUsageCore

extension Notification.Name {
    /// Posted by `AccountStore` on every change; tells the model to resync monitors.
    static let claudeCredentialsChanged = Notification.Name("claudeCredentialsChanged")
}

/// Owns one `AccountMonitor` per saved account, so all accounts are polled at once.
/// The menu bar shows the ACTIVE account; the popover shows every account.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var monitors: [AccountMonitor] = []

    private var childSubscriptions: [String: AnyCancellable] = [:]
    private var started = false

    init() { start() }

    func start() {
        guard !started else { return }
        started = true
        syncMonitors()
        NotificationCenter.default.addObserver(
            forName: .claudeCredentialsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncMonitors() }
        }
    }

    /// Match monitors to the store's accounts: start new ones, stop removed ones,
    /// let existing ones pick up a changed workspace pin. Keeps account order.
    private func syncMonitors() {
        let accounts = AccountStore.shared.accounts
        let existing = Dictionary(uniqueKeysWithValues: monitors.map { ($0.accountId, $0) })
        let ids = Set(accounts.map(\.id))
        for m in monitors where !ids.contains(m.accountId) {
            m.stop()
            childSubscriptions[m.accountId] = nil
        }
        monitors = accounts.map { acct in
            if let m = existing[acct.id] {
                Task { await m.reloadIfChanged() }
                return m
            }
            let m = AccountMonitor(accountId: acct.id)
            // Re-publish child changes so views observing the model (menu-bar label,
            // settings) update when any account's numbers change.
            childSubscriptions[acct.id] = m.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            return m
        }
        objectWillChange.send()   // active account / labels may have changed too
    }

    /// The account shown in the menu bar.
    var active: AccountMonitor? {
        let id = AccountStore.shared.activeId
        return monitors.first { $0.accountId == id } ?? monitors.first
    }

    // MARK: Active-account passthroughs (menu bar label, settings)

    var state: UsageState { active?.state ?? .waiting }
    var isSignedIn: Bool { monitors.contains { $0.isSignedIn } }
    var availableWorkspaces: [Workspace] { active?.availableWorkspaces ?? [] }
    var trackedOrgUUID: String? { active?.trackedOrgUUID }

    func refreshAll() async {
        for m in monitors { await m.refresh() }
    }
}
