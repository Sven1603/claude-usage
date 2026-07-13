import SwiftUI
import WebKit
import ClaudeUsageCore

/// Drives the in-app Claude login: web login → capture sessionKey → confirm → save.
@MainActor
final class LoginViewModel: ObservableObject {
    enum Step: Equatable { case login, notSignedIn, confirm }
    @Published var step: Step = .login
    @Published var capturedKey = ""
    @Published var orgLabel = ""
    @Published var usageLabel = ""
    @Published var revealKey = false

    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        // Best-effort: a desktop-Safari UA makes an embedded Google login less
        // likely to be blocked. Claude's email-code login works regardless.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                cont.resume(returning: $0)
            }
        }
    }

    func done() async {
        let cookies = await allCookies()
        guard let key = sessionKeyValue(from: cookies), !key.isEmpty else {
            step = .notSignedIn
            return
        }
        capturedKey = key
        orgLabel = ""
        usageLabel = ""
        if let (session, org, _) = try? await UsageClient().resolve(
            sessionKey: key, pinnedOrg: nil, now: Date()) {
            orgLabel = org.name ?? String(org.uuid.prefix(8))
            usageLabel = "\(session.percent)% · \(formatCountdown(seconds: session.secondsToReset))"
        }
        step = .confirm
    }

    func save() {
        AccountStore.shared.add(sessionKey: capturedKey,
                                label: orgLabel.isEmpty ? "Claude account" : orgLabel,
                                orgUUID: nil)
        // Don't retain a live Claude session in the app; the Keychain key is enough,
        // and a cleared web session lets the next "Add account" log into a different one.
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {}
        }
    }
}

private struct LoginWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ClaudeLoginView: View {
    @StateObject private var vm = LoginViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch vm.step {
            case .login, .notSignedIn:
                Text("Tip: if “Continue with Google” is blocked here, use **email + login code** instead — it works in this window. Then click Done.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.top, 8)
                if vm.step == .notSignedIn {
                    Text("Not signed in yet — finish logging in, then click Done.")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                LoginWebView(webView: vm.webView)
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Done") { Task { await vm.done() } }
                        .keyboardShortcut(.defaultAction)
                }.padding(10)
            case .confirm:
                confirmView
            }
        }
        .frame(width: 520, height: 640)
    }

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Captured session").font(.headline)
            Text("Optionally cross-check this against the sessionKey cookie in your browser, then Save.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if vm.revealKey {
                    Text(vm.capturedKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(String(repeating: "•", count: 24))
                }
                Spacer()
                Button(vm.revealKey ? "Hide" : "Reveal") { vm.revealKey.toggle() }
            }
            if !vm.usageLabel.isEmpty {
                Text("Current usage: \(vm.usageLabel)")
            }
            if !vm.orgLabel.isEmpty {
                Text("Org: \(vm.orgLabel)").foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Back") { vm.step = .login }
                Spacer()
                Button("Save") { vm.save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
