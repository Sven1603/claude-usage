import SwiftUI

struct SettingsView: View {
    private enum SaveStatus { case none, saved, failed }

    @State private var sessionKey: String = Keychain.sessionKey ?? ""
    @State private var orgUUID: String = Keychain.orgUUID ?? ""
    @State private var status: SaveStatus = .none
    @State private var launchRefresh = 0
    @State private var showingLogin = false
    @State private var signedIn = (Keychain.sessionKey?.isEmpty == false)
    @AppStorage("notifyOnReset") private var notifyOnReset = false

    private func signOut() {
        Keychain.sessionKey = nil
        Keychain.orgUUID = nil
        sessionKey = ""
        orgUUID = ""
        signedIn = false
        NotificationCenter.default.post(name: .claudeCredentialsChanged, object: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Usage — Settings").font(.headline)

            HStack {
                Button {
                    showingLogin = true
                } label: {
                    Label(signedIn ? "Sign in again" : "Sign in to Claude", systemImage: "person.crop.circle")
                }
                if signedIn {
                    Button("Sign out", role: .destructive) { signOut() }
                }
            }
            Text(signedIn
                 ? "Signed in. Your session key is stored in the macOS Keychain."
                 : "Signs you in and captures your session automatically — no DevTools needed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                        Button("Save") {
                            let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            let keyValue: String? = trimmed.isEmpty ? nil :
                                (trimmed.hasPrefix("sessionKey=") ? String(trimmed.dropFirst("sessionKey=".count)) : trimmed)
                            let org = orgUUID.trimmingCharacters(in: .whitespacesAndNewlines)
                            let orgValue: String? = org.isEmpty ? nil : org
                            let keyOK = Keychain.write(keyValue, account: "sessionKey")
                            let orgOK = Keychain.write(orgValue, account: "orgUUID")
                            status = (keyOK && orgOK) ? .saved : .failed
                            if keyOK && orgOK {
                                NotificationCenter.default.post(name: .claudeCredentialsChanged, object: nil)
                            }
                        }
                        switch status {
                        case .saved: Text("Saved").foregroundStyle(.green).font(.caption)
                        case .failed: Text("Couldn't save to Keychain").foregroundStyle(.red).font(.caption)
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
        .onChange(of: showingLogin) { showing in
            // Re-evaluate sign-in state when the login sheet closes (Save writes the key).
            if !showing { signedIn = (Keychain.sessionKey?.isEmpty == false) }
        }
    }
}
