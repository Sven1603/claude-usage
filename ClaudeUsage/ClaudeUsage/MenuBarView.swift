import SwiftUI
import AppKit
import ClaudeUsageCore

/// Window-style popover shown from the menu-bar item.
struct MenuBarView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject private var store = AccountStore.shared
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var sleepGuard: SleepGuard

    var body: some View {
        Group {
            if !model.isSignedIn {
                onboarding
            } else {
                signedInContainer {
                    if model.monitors.count == 1, let m = model.monitors.first {
                        AccountSectionView(monitor: m, showAccountHeader: false,
                                           isActive: true, compact: false,
                                           onSignIn: openSettings)
                    } else {
                        ForEach(model.monitors) { m in
                            AccountSectionView(monitor: m, showAccountHeader: true,
                                               isActive: m.accountId == model.active?.accountId,
                                               compact: true,
                                               onSignIn: openSettings)
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
            content()
            Divider()
            KeepAwakeRow(sleepGuard: sleepGuard)
            Divider()
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            Text("Claude Usage").font(.headline)
            Spacer()
            Button { Task { await model.refreshAll() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
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
            Text("Track your Claude session and weekly limits right in the menu bar.")
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
        let popover = NSApp.keyWindow   // the menu-bar popover is key while it's open
        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover?.close()                // dismiss the popover so it doesn't linger
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
            // Weekly-only plans count down days: "1d 1h" reads better than "25h0m".
            let countdown = s >= 86400 ? formatResetLong(seconds: s) : formatCountdown(seconds: s)
            return "\(p)% · \(countdown)"
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

/// One account in the popover: optional account header (click to show it in the
/// menu bar), its workspace picker, and its limit cards (or an auth card).
struct AccountSectionView: View {
    @ObservedObject var monitor: AccountMonitor
    let showAccountHeader: Bool
    let isActive: Bool
    let compact: Bool
    let onSignIn: () -> Void
    @ObservedObject private var store = AccountStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if showAccountHeader { accountHeader }
            if !(showAccountHeader && monitor.availableWorkspaces.count <= 1) {
                workspaceMenu
            }
            if case .authError = monitor.state {
                authCard
            } else if monitor.lastLimits.isEmpty, let error = monitor.lastError {
                errorCard(error)
            } else if monitor.lastLimits.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading…") }
                    .foregroundStyle(.secondary).padding(.vertical, compact ? 2 : 8)
            } else {
                ForEach(Array(monitor.lastLimits.enumerated()), id: \.offset) { _, limit in
                    LimitCardView(limit: limit, compact: compact)
                }
            }
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 6) {
            Text(monitor.label).font(.subheadline).bold().lineLimit(1)
            Spacer()
            if isActive {
                Label("In menu bar", systemImage: "menubar.rectangle")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Button("Show in menu bar") { store.setActive(id: monitor.accountId) }
                    .font(.caption2).buttonStyle(.borderless)
            }
        }
        .padding(.top, 2)
    }

    private var workspaceMenu: some View {
        Menu {
            ForEach(monitor.availableWorkspaces) { ws in
                Button {
                    store.setOrg(ws.id, for: monitor.accountId)
                } label: {
                    Text((ws.id == monitor.trackedOrgUUID ? "✓ " : "   ")
                         + ws.name + (ws.planLabel.map { " (\($0))" } ?? ""))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.2").font(.caption)
                Text(workspaceTitle).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var workspaceTitle: String {
        if let ws = monitor.availableWorkspaces.first(where: { $0.id == monitor.trackedOrgUUID }) {
            return ws.name + (ws.planLabel.map { " (\($0))" } ?? "")
        }
        return MenuBarView.orgName(for: monitor.state) ?? "Workspace"
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Can't load usage", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign in again") { onSignIn() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Session expired", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This account's session key is no longer valid. Sign in again to keep tracking.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Sign in again") { onSignIn() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// One usage limit rendered as a card.
struct LimitCardView: View {
    let limit: UsageLimit
    var compact: Bool = false

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// One-row variant used when several accounts share the popover.
    private var compactBody: some View {
        let sev = severity(forPercent: limit.percent)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kindIcon).font(.caption).foregroundStyle(.secondary)
                Text(limit.label).font(.caption)
                Spacer()
                Text("\(limit.percent)%").font(.caption).bold().foregroundStyle(color(sev))
                Text(formatResetLong(seconds: limit.secondsToReset))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            ProgressBar(fraction: Double(limit.percent) / 100.0, color: color(sev))
                .frame(height: 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder private var fullBody: some View {
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
