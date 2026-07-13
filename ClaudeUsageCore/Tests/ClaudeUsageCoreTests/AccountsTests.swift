import XCTest
@testable import ClaudeUsageCore

final class AccountsTests: XCTestCase {
    private func acct(_ id: String, _ label: String = "L") -> Account {
        Account(id: id, label: label, orgUUID: nil)
    }

    func test_addAppendsAndActivates() {
        var s = AccountsSnapshot(accounts: [], activeId: nil)
        s = addAccount(s, acct("a"))
        s = addAccount(s, acct("b"))
        XCTAssertEqual(s.accounts.map(\.id), ["a", "b"])
        XCTAssertEqual(s.activeId, "b")            // newest becomes active
        XCTAssertEqual(s.activeAccount?.id, "b")
    }

    func test_removeActivePicksFirstRemaining() {
        var s = AccountsSnapshot(accounts: [acct("a"), acct("b"), acct("c")], activeId: "b")
        s = removeAccount(s, id: "b")
        XCTAssertEqual(s.accounts.map(\.id), ["a", "c"])
        XCTAssertEqual(s.activeId, "a")            // active removed → first remaining
    }

    func test_removeNonActiveKeepsActive() {
        var s = AccountsSnapshot(accounts: [acct("a"), acct("b")], activeId: "b")
        s = removeAccount(s, id: "a")
        XCTAssertEqual(s.activeId, "b")
    }

    func test_removeLastClearsActive() {
        var s = AccountsSnapshot(accounts: [acct("a")], activeId: "a")
        s = removeAccount(s, id: "a")
        XCTAssertTrue(s.accounts.isEmpty)
        XCTAssertNil(s.activeId)
        XCTAssertNil(s.activeAccount)
    }

    func test_setActivePresentVsAbsent() {
        var s = AccountsSnapshot(accounts: [acct("a"), acct("b")], activeId: "a")
        s = setActiveAccount(s, id: "b")
        XCTAssertEqual(s.activeId, "b")
        s = setActiveAccount(s, id: "zzz")         // absent → unchanged
        XCTAssertEqual(s.activeId, "b")
    }

    func test_accountCodableRoundTrip() throws {
        let a = Account(id: "x", label: "Company", orgUUID: "org-1")
        let data = try JSONEncoder().encode([a])
        let back = try JSONDecoder().decode([Account].self, from: data)
        XCTAssertEqual(back, [a])
    }
}
