import Foundation
import UserNotifications

@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    private var isRequested = false
    private var lastSentAt: [String: Date] = [:]

    private init() {}

    func requestIfNeeded() {
        guard !isRequested else { return }
        isRequested = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
}
