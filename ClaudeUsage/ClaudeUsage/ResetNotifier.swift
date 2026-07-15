import UserNotifications
import ClaudeUsageCore

/// Local notifications: limit reset + session threshold alerts.
enum ResetNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func notifyReset() {
        notify(title: "Claude limit reset",
               body: "Your 5-hour session limit has reset.",
               identifier: "claude-limit-reset")
    }

    static func notifyThreshold(_ alert: ThresholdAlert, percent: Int) {
        switch alert {
        case .warning:
            notify(title: "Claude usage warning",
                   body: "Your 5-hour session is at \(percent)%.",
                   identifier: "claude-usage-warning")
        case .critical:
            notify(title: "Claude usage critical",
                   body: "Your 5-hour session is at \(percent)% — nearly out.",
                   identifier: "claude-usage-critical")
        }
    }

    static func sendTest() {
        // Mirror the (working) reset path: post directly. Auth is already granted;
        // foreground presentation is handled by the app's notification delegate.
        notify(title: "Claude Usage",
               body: "Test notification — alerts are working.",
               identifier: "claude-usage-test")
    }
}
