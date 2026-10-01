import DaptasticCore
import UserNotifications

/// macOS notifications for the two moments a menu-bar app needs to reach you: the player being
/// plugged in, and a sync ending (or needing a decision). Clicks are routed back via `onAction`.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String {
        case cardConnected = "card-connected"
        case syncFinished = "sync-finished"
        /// Won't fit, delete confirmation, failure: clicking opens the window with details.
        case needsAttention = "needs-attention"
        case updateAvailable = "update-available"
    }

    enum Action: String {
        case sync, eject, install
        /// The notification itself was clicked.
        case open
    }

    var onAction: (Kind, Action) -> Void = { _, _ in }
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.cardConnected.rawValue, actions: [
                UNNotificationAction(identifier: Action.sync.rawValue, title: "Sync Now"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.syncFinished.rawValue, actions: [
                UNNotificationAction(identifier: Action.eject.rawValue, title: "Eject"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.needsAttention.rawValue, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.updateAvailable.rawValue, actions: [
                UNNotificationAction(identifier: Action.install.rawValue, title: "Install…"),
            ], intentIdentifiers: []),
        ])
    }

    func status() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Shows macOS's permission prompt the first time; afterwards just reports the answer.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// One notification per kind: a newer one replaces the older.
    func post(_ kind: Kind, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = kind.rawValue
        if kind != .syncFinished { content.sound = .default }
        // You've just plugged the player in, so this one may break through a Focus mode.
        // Needs the time-sensitive entitlement; without it macOS treats it as a normal notification.
        if kind == .cardConnected { content.interruptionLevel = .timeSensitive }
        center.add(UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil))
    }

    func remove(_ kind: Kind) {
        center.removeDeliveredNotifications(withIdentifiers: [kind.rawValue])
        center.removePendingNotificationRequests(withIdentifiers: [kind.rawValue])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while a Daptastic window is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let kind = Kind(rawValue: response.notification.request.content.categoryIdentifier) else { return }
        let action = Action(rawValue: response.actionIdentifier) ?? .open
        await MainActor.run { onAction(kind, action) }
    }
}
