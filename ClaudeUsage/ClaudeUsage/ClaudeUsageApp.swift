import SwiftUI
import AppKit

@main
struct ClaudeUsageApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // Settings window, opened via the dropdown (openWindow(id: "settings")).
        Window("Claude Usage Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)   // merge the title bar into the icon toolbar
    }
}

/// The menu-bar item's label. Also opens Settings once on launch if no one is
/// signed in yet, so first-time users are prompted to log in.
struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    @Environment(\.openWindow) private var openWindow
    @State private var promptedForLogin = false

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: ProgressBarImage.make(
                percent: MenuBarView.labelPercent(for: model.state),
                dimmed: MenuBarView.isDimmed(model.state)))
            Text(MenuBarView.labelText(for: model.state))
        }
        .onAppear {
            guard !promptedForLogin else { return }
            promptedForLogin = true
            if !model.isSignedIn {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
        }
    }
}
