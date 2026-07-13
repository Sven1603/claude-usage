import SwiftUI
import AppKit
import ClaudeUsageCore

/// Contents of the menu bar dropdown.
struct MenuBarView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var store = AccountStore.shared

    /// Agent apps (LSUIElement) open windows behind other apps unless activated.
    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    var body: some View {
        Group {
            switch model.state {
            case .waiting:
                Text("Waiting for data…")
            case .authError:
                Text("Session key invalid or expired")
                Button("Fix session key…") { openSettings() }
            case .resetting:
                Text("Session resetting…")
            case .ok, .stale:
                Text("Claude usage").foregroundStyle(.secondary)
                ForEach(Array(model.lastLimits.enumerated()), id: \.offset) { _, limit in
                    Text("\(limit.label)   \(limit.percent)% · \(formatResetLong(seconds: limit.secondsToReset))")
                }
                if let org = Self.orgName(for: model.state) {
                    Divider()
                    Text("Org: \(org)").foregroundStyle(.secondary)
                }
            }
            if store.accounts.count > 1 {
                Divider()
                Text("Accounts").foregroundStyle(.secondary)
                ForEach(store.accounts) { account in
                    Button {
                        store.setActive(id: account.id)
                    } label: {
                        Text((account.id == store.activeId ? "✓ " : "   ") + account.label)
                    }
                }
            }
            Divider()
            Button("Refresh now") { Task { await model.refresh() } }
            Button("Settings…") { openSettings() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    /// The tracked org name for the current state (for the dropdown).
    static func orgName(for state: UsageState) -> String? {
        switch state {
        case let .ok(_, _, org), let .stale(_, _, org): return org
        default: return nil
        }
    }

    /// Text shown next to the bar in the menu bar itself.
    static func labelText(for state: UsageState) -> String {
        switch state {
        case .waiting: return "—"
        case .authError: return "⚠︎ Auth"
        case .resetting: return "Resetting…"
        case let .ok(p, s, _), let .stale(p, s, _):
            return "\(p)% · \(formatCountdown(seconds: s))"
        }
    }

    /// Percent for the bar image (0 when no data).
    static func labelPercent(for state: UsageState) -> Int {
        switch state {
        case let .ok(p, _, _), let .stale(p, _, _): return p
        default: return 0
        }
    }

    static func isDimmed(_ state: UsageState) -> Bool {
        if case .stale = state { return true }
        return false
    }
}
