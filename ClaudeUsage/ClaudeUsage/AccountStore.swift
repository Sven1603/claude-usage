import Foundation
import Combine
import ClaudeUsageCore

/// Shared store of Claude accounts. Metadata persists to UserDefaults; session keys
/// live in the Keychain keyed by account id. Posts `.claudeCredentialsChanged` on
/// every change so `UsageModel` re-reads the active account.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var snapshot: AccountsSnapshot

    private let defaults = UserDefaults.standard
    private let accountsKey = "accounts"
    private let activeKey = "activeAccountId"

    var accounts: [Account] { snapshot.accounts }
    var activeId: String? { snapshot.activeId }
    var activeAccount: Account? { snapshot.activeAccount }

    /// The active account's session key from the Keychain (nil if none/not stored).
    var activeSessionKey: String? {
        guard let id = snapshot.activeId else { return nil }
        return Keychain.get(account: keyAccount(id))
    }

    private init() {
        let accts: [Account]
        if let data = defaults.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accts = decoded
        } else {
            accts = []
        }
        snapshot = AccountsSnapshot(accounts: accts, activeId: defaults.string(forKey: activeKey))
        migrateLegacyIfNeeded()
    }

    private func keyAccount(_ id: String) -> String { "session.\(id)" }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot.accounts) {
            defaults.set(data, forKey: accountsKey)
        }
        defaults.set(snapshot.activeId, forKey: activeKey)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .claudeCredentialsChanged, object: nil)
    }

    @discardableResult
    func add(sessionKey: String, label: String, orgUUID: String?) -> Account {
        let account = Account(id: UUID().uuidString, label: label, orgUUID: orgUUID)
        Keychain.set(sessionKey, account: keyAccount(account.id))
        snapshot = addAccount(snapshot, account)
        persist()
        notifyChanged()
        return account
    }

    func remove(id: String) {
        Keychain.delete(account: keyAccount(id))
        snapshot = removeAccount(snapshot, id: id)
        persist()
        notifyChanged()
    }

    func setActive(id: String) {
        snapshot = setActiveAccount(snapshot, id: id)
        persist()
        notifyChanged()
    }

    /// One-time: fold the legacy single `sessionKey`(+`orgUUID`) into one account.
    private func migrateLegacyIfNeeded() {
        guard snapshot.accounts.isEmpty,
              let legacyKey = Keychain.get(account: "sessionKey"), !legacyKey.isEmpty
        else { return }
        let account = Account(id: UUID().uuidString, label: "Claude account",
                              orgUUID: Keychain.get(account: "orgUUID"))
        Keychain.set(legacyKey, account: keyAccount(account.id))
        Keychain.delete(account: "sessionKey")
        Keychain.delete(account: "orgUUID")
        snapshot = addAccount(snapshot, account)
        persist()
    }
}
