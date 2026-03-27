import Foundation
import UserNotifications

@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    private var isRequested = false

    private init() {}

    func requestIfNeeded() {
        guard !isRequested else { return }
        isRequested = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
