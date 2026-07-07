import SwiftUI

struct SettingsView: View {
    private enum SaveStatus { case none, saved, failed }

    @State private var sessionKey: String = Keychain.sessionKey ?? ""
    @State private var orgUUID: String = Keychain.orgUUID ?? ""
    @State private var status: SaveStatus = .none
    // Bumped after toggling launch-at-login to force the toggle to re-read the
    // real system state (which may be .requiresApproval, not a clean .enabled).
    @State private var launchRefresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Usage — Settings").font(.headline)
            Text("Paste your claude.ai sessionKey. It is stored only in your macOS Keychain and sent only to claude.ai.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sessionKey", text: $sessionKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: sessionKey) { _ in status = .none }

            Text("Org UUID (optional — leave blank to auto-detect the active org):")
                .font(.caption).foregroundStyle(.secondary)
            TextField("organization uuid", text: $orgUUID)
                .textFieldStyle(.roundedBorder)
                .onChange(of: orgUUID) { _ in status = .none }

            Toggle("Launch at login", isOn: Binding(
                get: { _ = launchRefresh; return LaunchAtLogin.isEnabled },
                set: { LaunchAtLogin.set($0); launchRefresh += 1 }
            ))
            .toggleStyle(.switch)

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
                }
                switch status {
                case .saved: Text("Saved").foregroundStyle(.green).font(.caption)
                case .failed: Text("Couldn't save to Keychain").foregroundStyle(.red).font(.caption)
                case .none: EmptyView()
                }
                Spacer()
                Link("How to get your key", destination: URL(string: "https://github.com/Sven1603/claude-usage#getting-your-sessionkey")!)
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
