import SwiftUI
import AppKit
import UserNotifications

/// Registers as the notification delegate so alerts present even while the app is
/// frontmost — otherwise macOS silently drops them to Notification Center, which is
/// why "Send Test" (clicked with Settings frontmost) showed nothing.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        // Set eagerly in init() — in a MenuBarExtra-only app applicationDidFinishLaunching
        // is not reliably called, which left foreground notifications (e.g. Send Test,
        // clicked with Settings frontmost) suppressed while background ones still showed.
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
