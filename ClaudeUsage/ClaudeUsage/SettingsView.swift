import SwiftUI
import ClaudeUsageCore

struct SettingsView: View {
    private enum SaveStatus { case none, saved, failed }

    @ObservedObject private var store = AccountStore.shared
    @ObservedObject var model: UsageModel
    @State private var sessionKey = ""
    @State private var orgUUID = ""
    @State private var status: SaveStatus = .none
    @State private var launchRefresh = 0
    @State private var showingLogin = false
    @AppStorage("notifyOnReset") private var notifyOnReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Usage — Settings").font(.headline)

            if store.accounts.isEmpty {
                Button { showingLogin = true } label: {
                    Label("Sign in to Claude", systemImage: "person.crop.circle")
                }
                Text("Signs you in and captures your session automatically — no DevTools needed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Accounts").font(.subheadline).foregroundStyle(.secondary)
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
                        }
                        .help("Remove this account")
                    }
                }
                Button { showingLogin = true } label: {
                    Label("Add account…", systemImage: "plus")
                }
            }

            if model.availableWorkspaces.count > 1 {
                Text("Workspaces").font(.subheadline).foregroundStyle(.secondary)
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

            Toggle("Notify me when my limit resets", isOn: $notifyOnReset)
                .toggleStyle(.switch)
                .onChange(of: notifyOnReset) { on in
                    if on { ResetNotifier.requestAuthorization() }
                }

            Toggle("Launch at login", isOn: Binding(
                get: { _ = launchRefresh; return LaunchAtLogin.isEnabled },
                set: { LaunchAtLogin.set($0); launchRefresh += 1 }
            ))
            .toggleStyle(.switch)

            DisclosureGroup("Advanced — paste session key manually") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("sessionKey", text: $sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sessionKey) { _ in status = .none }
                    Text("Org UUID (optional — leave blank to auto-detect):")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("organization uuid", text: $orgUUID)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: orgUUID) { _ in status = .none }
                    HStack {
                        Button("Add account") {
                            let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { status = .failed; return }
                            let keyValue = trimmed.hasPrefix("sessionKey=")
                                ? String(trimmed.dropFirst("sessionKey=".count)) : trimmed
                            let org = orgUUID.trimmingCharacters(in: .whitespacesAndNewlines)
                            store.add(sessionKey: keyValue, label: "Account",
                                      orgUUID: org.isEmpty ? nil : org)
                            sessionKey = ""; orgUUID = ""
                            status = .saved
                        }
                        switch status {
                        case .saved: Text("Added").foregroundStyle(.green).font(.caption)
                        case .failed: Text("Enter a session key").foregroundStyle(.red).font(.caption)
                        case .none: EmptyView()
                        }
                        Spacer()
                        Link("How to get your key",
                             destination: URL(string: "https://github.com/Sven1603/claude-usage#getting-your-sessionkey")!)
                            .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 400)
        .sheet(isPresented: $showingLogin) { ClaudeLoginView() }
    }
}
