import SwiftUI
import ClaudeUsageCore

struct SettingsView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440)
        .frame(minHeight: 460)
    }
}

private struct GeneralSettingsView: View {
    private enum SaveStatus { case none, added, failed }
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject var model: UsageModel
    @State private var sessionKey = ""
    @State private var orgUUID = ""
    @State private var status: SaveStatus = .none
    @State private var launchRefresh = 0
    @State private var showingLogin = false
    @AppStorage("notifyOnReset") private var notifyOnReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Accounts") {
                    VStack(alignment: .leading, spacing: 8) {
                        if store.accounts.isEmpty {
                            Text("Not signed in.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(store.accounts) { account in
                                HStack {
                                    Image(systemName: account.id == store.activeId ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(account.id == store.activeId ? Color.green : Color.secondary)
                                    Text(account.label)
                                    Spacer()
                                    if account.id != store.activeId {
                                        Button("Use") { store.setActive(id: account.id) }
                                    }
                                    Button(role: .destructive) { store.remove(id: account.id) } label: {
                                        Image(systemName: "trash")
                                    }.help("Remove this account")
                                }
                            }
                        }
                        Button { showingLogin = true } label: {
                            Label(store.accounts.isEmpty ? "Sign in to Claude" : "Add account…",
                                  systemImage: store.accounts.isEmpty ? "person.crop.circle" : "plus")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                if model.availableWorkspaces.count > 1 {
                    GroupBox("Workspaces") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.availableWorkspaces) { ws in
                                HStack {
                                    Image(systemName: ws.id == model.trackedOrgUUID ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(ws.id == model.trackedOrgUUID ? Color.green : Color.secondary)
                                    Text(ws.name + (ws.planLabel.map { " (\($0))" } ?? ""))
                                    Spacer()
                                    if ws.id != model.trackedOrgUUID {
                                        Button("Use") { store.setActiveAccountOrg(ws.id) }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }

                GroupBox("Notifications") {
                    Toggle("Notify me when my limit resets", isOn: $notifyOnReset)
                        .toggleStyle(.switch)
                        .onChange(of: notifyOnReset) { on in if on { ResetNotifier.requestAuthorization() } }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("Startup") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { _ = launchRefresh; return LaunchAtLogin.isEnabled },
                        set: { LaunchAtLogin.set($0); launchRefresh += 1 }
                    ))
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste a session key manually (fallback if in-app sign-in is blocked).")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("sessionKey", text: $sessionKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: sessionKey) { _ in status = .none }
                        TextField("organization uuid (optional)", text: $orgUUID)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: orgUUID) { _ in status = .none }
                        HStack {
                            Button("Add account") {
                                let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { status = .failed; return }
                                let keyValue = trimmed.hasPrefix("sessionKey=")
                                    ? String(trimmed.dropFirst("sessionKey=".count)) : trimmed
                                let org = orgUUID.trimmingCharacters(in: .whitespacesAndNewlines)
                                store.add(sessionKey: keyValue, label: "Account", orgUUID: org.isEmpty ? nil : org)
                                sessionKey = ""; orgUUID = ""; status = .added
                            }
                            switch status {
                            case .added: Text("Added").foregroundStyle(.green).font(.caption)
                            case .failed: Text("Enter a session key").foregroundStyle(.red).font(.caption)
                            case .none: EmptyView()
                            }
                            Spacer()
                            Link("How to get your key",
                                 destination: URL(string: "https://github.com/Sven1603/claude-usage#getting-your-sessionkey")!)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showingLogin) { ClaudeLoginView() }
    }
}

private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Claude Usage").font(.headline)
            Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
            Text("Live Claude 5-hour and weekly usage in your menu bar.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Link("github.com/Sven1603/claude-usage",
                 destination: URL(string: "https://github.com/Sven1603/claude-usage")!)
                .font(.caption)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
