import Foundation
import UserNotifications

@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    private var isRequested = false
    private var lastSentAt: [String: Date] = [:]

    private override init() {}

    func requestIfNeeded() {
        guard !isRequested else { return }
        isRequested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(
        id: String? = nil,
        title: String,
        body: String,
        minimumInterval: TimeInterval = 60
    ) {
        let key = id ?? "\(title)|\(body)"
        let now = Date()
        if let last = lastSentAt[key], now.timeIntervalSince(last) < minimumInterval {
            return
        }
        lastSentAt[key] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.sound])
        }
    }
}
