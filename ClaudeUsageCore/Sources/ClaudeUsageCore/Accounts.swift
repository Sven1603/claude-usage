import Foundation

/// One saved Claude account. The session key itself is NOT here — it lives in the
/// Keychain keyed by `id`; this is just metadata persisted to UserDefaults.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var orgUUID: String?
    public init(id: String, label: String, orgUUID: String?) {
        self.id = id; self.label = label; self.orgUUID = orgUUID
    }
}

/// The set of accounts plus which one is active.
public struct AccountsSnapshot: Equatable, Sendable {
    public var accounts: [Account]
    public var activeId: String?
    public init(accounts: [Account], activeId: String?) {
        self.accounts = accounts; self.activeId = activeId
    }
    public var activeAccount: Account? { accounts.first { $0.id == activeId } }
}

/// Append an account and make it active.
public func addAccount(_ s: AccountsSnapshot, _ account: Account) -> AccountsSnapshot {
    AccountsSnapshot(accounts: s.accounts + [account], activeId: account.id)
}

/// Remove an account. If it was active, the first remaining account becomes active
/// (nil if none remain).
public func removeAccount(_ s: AccountsSnapshot, id: String) -> AccountsSnapshot {
    let remaining = s.accounts.filter { $0.id != id }
    let active = s.activeId == id ? remaining.first?.id : s.activeId
    return AccountsSnapshot(accounts: remaining, activeId: active)
}

/// Make `id` active if it exists; otherwise unchanged.
public func setActiveAccount(_ s: AccountsSnapshot, id: String) -> AccountsSnapshot {
    guard s.accounts.contains(where: { $0.id == id }) else { return s }
    return AccountsSnapshot(accounts: s.accounts, activeId: id)
}
