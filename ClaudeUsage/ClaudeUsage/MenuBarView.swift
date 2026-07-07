import SwiftUI
import AppKit
import ClaudeUsageCore

/// Contents of the menu bar dropdown.
struct MenuBarView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.openWindow) private var openWindow

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
            case let .ok(percent, secs, org), let .stale(percent, secs, org):
                Text("Claude 5-hour session")
                Text("\(percent)% used")
                Text("Resets in \(formatCountdown(seconds: secs))")
                if let org { Text("Org: \(org)").foregroundStyle(.secondary) }
            }
            Divider()
            Button("Refresh now") { Task { await model.refresh() } }
            Button("Settings…") { openSettings() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
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
