import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            HStack(spacing: 2) {
                Image(nsImage: ProgressBarImage.make(
                    percent: MenuBarView.labelPercent(for: model.state),
                    dimmed: MenuBarView.isDimmed(model.state)))
                Text(MenuBarView.labelText(for: model.state))
            }
        }
        .menuBarExtraStyle(.menu)

        // Settings window, opened via the dropdown (openWindow(id: "settings")).
        Window("Claude Usage Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
