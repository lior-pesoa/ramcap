import Foundation
import UserNotifications

/// Posts the warning, pending-stop and stop notifications. Needs a real app
/// bundle; it does nothing when run as a bare executable.
@MainActor
final class Notifier {
    enum Response { case protect, stopNow }

    static let pendingID = "pending-stop"
    private static let pendingCategory = "PENDING_STOP"
    private static let protectAction = "PROTECT"
    private static let stopNowAction = "STOP_NOW"

    /// Called when someone presses Protect or Stop now on a pending-stop notification.
    static var onResponse: ((Response) -> Void)?

    private let delegate = Delegate()

    init?() {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.pendingCategory,
            actions: [UNNotificationAction(identifier: Self.protectAction, title: "Protect"),
                      UNNotificationAction(identifier: Self.stopNowAction, title: "Stop now", options: .destructive)],
            intentIdentifiers: [])])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String) {
        post(id: UUID().uuidString, title: title, body: body, category: nil)
    }

    /// Replaces any earlier pending-stop notification.
    func sendPending(title: String, body: String) {
        post(id: Self.pendingID, title: title, body: body, category: Self.pendingCategory)
    }

    func clearPending() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.pendingID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.pendingID])
    }

    private func post(id: String, title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        /// Show banners even while RAMcap's panel is open (the app is then frontmost).
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
            async -> UNNotificationPresentationOptions { [.banner, .sound] }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let response: Response? = switch response.actionIdentifier {
            case Notifier.protectAction: .protect
            case Notifier.stopNowAction: .stopNow
            default: nil
            }
            guard let response else { return }
            await MainActor.run { Notifier.onResponse?(response) }
        }
    }
}
