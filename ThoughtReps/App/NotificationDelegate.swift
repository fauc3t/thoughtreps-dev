import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Completion-handler variants on purpose: the `async` ones return to UIKit off the main
    // thread, which crashes with "Call must be made on main thread" when a reminder is tapped.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if identifier.hasPrefix(NotificationScheduler.identifierPrefix)
                || identifier.hasPrefix(NotificationScheduler.testIdentifierPrefix) {
                AppNavigation.shared.openTimelineFromReminder()
            }
            completionHandler()
        }
    }
}
