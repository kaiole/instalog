import InstalogCore
import UserNotifications

/// Keeps the pending "Logged …" notifications in step with the schedules that ask for one.
/// Notifications only report; the meal itself logs in the app, at its time or when it next opens.
enum ScheduleNotifier {
    /// Asks for permission the first time a schedule turns notifications on. False if refused.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Replaces every pending schedule notification with the current plan.
    @MainActor
    static func reconcile(_ model: DiaryModel) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(PlannedNotification.identifierPrefix) })
        let plan = await model.notificationPlan()
        guard !plan.isEmpty, await isAuthorized() else { return }
        for item in plan {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
            let request = UNNotificationRequest(
                identifier: item.id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }

    /// True when notifications are already allowed. Never prompts.
    private static func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}
