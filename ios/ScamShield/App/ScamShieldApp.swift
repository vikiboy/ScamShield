import SwiftUI
import UIKit
import UserNotifications

@main
struct ScamShieldApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(InboxStore.shared)
                .environment(Router.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await InboxStore.shared.refresh() }
            case .background:
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}

/// Sets the notification delegate at launch so taps on alerts that started the app are delivered.
/// (Background refresh is scheduled when the scene goes to the background and after each run.)
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let itemID = response.notification.request.content.userInfo[Notifier.itemIDKey] as? String else { return }
        await MainActor.run {
            let bucket = InboxStore.shared.item(withID: itemID)?.bucket ?? .attention
            Router.shared.open(itemID: itemID, in: bucket)
        }
    }
}
