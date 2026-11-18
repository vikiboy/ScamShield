import BackgroundTasks
import Foundation
import os
import UserNotifications

/// Local notifications for new Attention calls. There is no push on a free Apple ID, so these are
/// posted by the app itself after a foreground or background refresh.
enum Notifier {
    static let itemIDKey = "itemId"
    private static let log = Logger(subsystem: "local.scamshield", category: "notify")

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func post(_ items: [Item]) async {
        let center = UNUserNotificationCenter.current()
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = NotificationPlanner.title(for: item)
            content.body = NotificationPlanner.body(for: item)
            content.sound = .default
            content.userInfo = [itemIDKey: item.id]
            content.threadIdentifier = "attention"
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                log.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// App icon badge = open Attention calls.
    static func setBadge(_ count: Int) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.badgeSetting == .enabled else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// The BGAppRefreshTask that lets iOS wake the app to check for new calls.
enum BackgroundRefresh {
    static let identifier = "local.scamshield.refresh"
    private static let log = Logger(subsystem: "local.scamshield", category: "background")

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the simulator and when Background App Refresh is off.
            log.notice("Background refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    static func run() async {
        schedule()
        await InboxStore.shared.refresh()
    }
}
