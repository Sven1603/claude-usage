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

    /// `account` is the account name when more than one account is tracked
    /// (nil keeps the single-account wording).
    static func notifyReset(limitLabel: String, account: String?, accountId: String) {
        notify(title: prefixed("Claude limit reset", account),
               body: "Your \(lowerFirst(limitLabel)) limit has reset.",
               identifier: "claude-limit-reset-\(accountId)")
    }

    static func notifyThreshold(_ alert: ThresholdAlert, percent: Int, limitLabel: String,
                                account: String?, accountId: String) {
        switch alert {
        case .warning:
            notify(title: prefixed("Claude usage warning", account),
                   body: "Your \(lowerFirst(limitLabel)) is at \(percent)%.",
                   identifier: "claude-usage-warning-\(accountId)")
        case .critical:
            notify(title: prefixed("Claude usage critical", account),
                   body: "Your \(lowerFirst(limitLabel)) is at \(percent)%, nearly out.",
                   identifier: "claude-usage-critical-\(accountId)")
        }
    }

    /// "Weekly (Fable)" -> "weekly (Fable)" so it reads mid-sentence.
    private static func lowerFirst(_ s: String) -> String {
        s.prefix(1).lowercased() + s.dropFirst()
    }

    private static func prefixed(_ title: String, _ account: String?) -> String {
        guard let account, !account.isEmpty else { return title }
        return "\(title) · \(account)"
    }

    static func notifySleepRestored(_ reason: SleepRestoreReason, capHours: Int) {
        notify(title: "Sleep re-enabled",
               body: sleepRestoredMessage(for: reason, capHours: capHours),
               identifier: "claude-usage-sleep-restored")
    }

    static func sendTest() {
        // Mirror the (working) reset path: post directly. Auth is already granted;
        // foreground presentation is handled by the app's notification delegate.
        notify(title: "Claude Usage",
               body: "Test notification — alerts are working.",
               identifier: "claude-usage-test")
    }
}
