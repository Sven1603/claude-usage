import SwiftUI
import ClaudeUsageCore

/// The dropdown toggle. All wording comes from keepAwakeSubtitle so it stays testable.
struct KeepAwakeRow: View {
    @ObservedObject var sleepGuard: SleepGuard
    @State private var showingExplainer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Keep awake with lid closed").font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { sleepGuard.isOn },
                    set: { on in
                        // First run explains what this changes before macOS asks
                        // for an admin password out of nowhere.
                        if on && sleepGuard.needsSetup { showingExplainer = true }
                        else { Task { await sleepGuard.toggle(on) } }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text(keepAwakeSubtitle(sleepGuard.uiState))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingExplainer) {
            KeepAwakeExplainer(
                capHours: sleepGuard.capHours,
                onCancel: { showingExplainer = false },
                onContinue: {
                    showingExplainer = false
                    Task { await sleepGuard.setUpAndEnable() }
                })
        }
    }
}

/// Shown once, before the first admin prompt.
struct KeepAwakeExplainer: View {
    /// The cap the user actually has configured, not the default.
    let capHours: Int
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep awake with lid closed").font(.headline)
            Text("""
                 Your Mac normally sleeps the moment you close the lid, which ends \
                 any running Claude Code session. This turns that off while you need it.
                 """)
                .font(.callout)
            Text("macOS will ask you to approve a background helper. That happens once.")
                .font(.callout)

            GroupBox("Sleep comes back automatically when") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Nothing has been running for 2 minutes", systemImage: "moon")
                    Label(keepAwakeCapLine(capHours: capHours), systemImage: "timer")
                    Label("Battery drops below 20%", systemImage: "battery.25")
                    Label("Claude Usage quits or crashes", systemImage: "xmark.circle")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Text("""
                 A Mac left awake in a bag will keep using battery and getting warm. \
                 Turn this off when you are done.
                 """)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Continue", action: onContinue).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
