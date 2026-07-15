import SwiftUI
import AppKit
import ClaudeUsageCore

/// Window-style popover shown from the menu-bar item.
struct MenuBarView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject private var store = AccountStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !model.isSignedIn {
                onboarding
            } else if case .authError = model.state {
                signedInContainer { authCard }
            } else {
                signedInContainer {
                    if model.lastLimits.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Loading…") }
                            .foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(Array(model.lastLimits.enumerated()), id: \.offset) { _, limit in
                            LimitCardView(limit: limit)
                        }
                    }
                }
            }
        }
        .frame(width: 300)
    }

    // MARK: Sections

    private func signedInContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            workspaceMenu
            content()
            Divider()
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            Text("Claude Usage").font(.headline)
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
    }

    private var workspaceMenu: some View {
        Menu {
            ForEach(model.availableWorkspaces) { ws in
                Button {
                    store.setActiveAccountOrg(ws.id)
                } label: {
                    Text((ws.id == model.trackedOrgUUID ? "✓ " : "   ")
                         + ws.name + (ws.planLabel.map { " (\($0))" } ?? ""))
                }
            }
            if store.accounts.count > 1 {
                Divider()
                ForEach(store.accounts) { acct in
                    Button { store.setActive(id: acct.id) } label: {
                        Text((acct.id == store.activeId ? "✓ " : "   ") + acct.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.2").font(.caption)
                Text(activeWorkspaceTitle).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var activeWorkspaceTitle: String {
        if let ws = model.availableWorkspaces.first(where: { $0.id == model.trackedOrgUUID }) {
            return ws.name + (ws.planLabel.map { " (\($0))" } ?? "")
        }
        return Self.orgName(for: model.state) ?? "Workspace"
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Session expired", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Your session key is no longer valid. Sign in again to keep tracking.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Sign in again") { openSettings() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettings() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private var onboarding: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text("Welcome to Claude Usage").font(.headline)
            Text("Track your Claude 5-hour and weekly limits right in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { openSettings() } label: {
                Label("Sign in to Claude", systemImage: "person.crop.circle")
            }
            .buttonStyle(.borderedProminent)
            Divider()
            footer
        }
        .padding(16)
    }

    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    // MARK: Menu-bar label helpers (used by MenuBarLabel)

    static func orgName(for state: UsageState) -> String? {
        switch state {
        case let .ok(_, _, org), let .stale(_, _, org): return org
        default: return nil
        }
    }
    static func labelText(for state: UsageState) -> String {
        switch state {
        case .waiting: return "—"
        case .authError: return "⚠︎ Auth"
        case .resetting: return "Resetting…"
        case let .ok(p, s, _), let .stale(p, s, _):
            return "\(p)% · \(formatCountdown(seconds: s))"
        }
    }
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

/// One usage limit rendered as a card.
struct LimitCardView: View {
    let limit: UsageLimit

    var body: some View {
        let sev = severity(forPercent: limit.percent)
        let over = isOverPace(percent: limit.percent,
                              secondsToReset: limit.secondsToReset,
                              windowSeconds: windowSeconds(forKind: limit.kind))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: kindIcon).foregroundStyle(.secondary)
                Text(limit.label).font(.subheadline).bold()
                Spacer()
                pill(sev)
            }
            Text("\(limit.percent)%").font(.title2).bold().foregroundStyle(color(sev))
            ProgressBar(fraction: Double(limit.percent) / 100.0, color: color(sev))
                .frame(height: 6)
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                Text("Resets in \(formatResetLong(seconds: limit.secondsToReset))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if over {
                    Image(systemName: "flame.fill").font(.caption).foregroundStyle(.orange)
                        .help("Using faster than sustainable")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var kindIcon: String {
        if limit.kind == "session" { return "clock" }
        if limit.kind == "weekly_scoped" { return "sparkles" }
        return "calendar"
    }

    private func color(_ s: UsageSeverity) -> Color {
        switch s {
        case .safe: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func pill(_ s: UsageSeverity) -> some View {
        let text: String
        let icon: String
        switch s {
        case .safe: text = "Safe"; icon = "checkmark.circle.fill"
        case .warning: text = "Warning"; icon = "exclamationmark.triangle.fill"
        case .critical: text = "Critical"; icon = "xmark.circle.fill"
        }
        return Label(text, systemImage: icon)
            .font(.caption2).bold()
            .foregroundStyle(color(s))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color(s).opacity(0.15)))
    }
}

/// A simple rounded progress bar.
struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}
