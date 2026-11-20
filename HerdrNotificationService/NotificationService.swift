import UserNotifications
import WidgetKit

/// Gives an omp question push (#483) its answer buttons, and lets a critical gram fall back to
/// time-sensitive while critical alerts are not allowed. iOS runs this for every push with
/// `mutable-content`; only those two are changed, and every other push is delivered exactly
/// as it arrived (agent alerts also update the home-screen widgets' snapshot).
///
/// Buttons need a registered category, and each question's buttons are its own options, so
/// each question registers a category of its own before its notification is shown. The
/// actions require an unlocked device: an answer is sent with the phone's SSH key, which the
/// Keychain only releases then, and a locked phone must not be able to steer an agent.
final class NotificationService: UNNotificationServiceExtension {
    /// Called once: by the category registration finishing or by the time limit, whichever
    /// comes first, on whatever threads iOS and the task run on.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        original = request.content
        // Any agent alert, answerable or not, moves the home-screen widgets' waiting agent.
        if let next = WidgetSnapshot.applying(alert: request.content.userInfo,
                                              to: WidgetSnapshot.load(), now: Date()) {
            next.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
        let ask = AskPush(userInfo: request.content.userInfo)
        let critical = (request.content.userInfo["aps"] as? [String: Any])?["interruption-level"] as? String == "critical"
        guard ask != nil || critical,
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        Task {
            if let ask {
                let category = AskCategory(ask)
                await Self.register(category)
                content.categoryIdentifier = category.identifier
            }
            // An agent's emergency (`herdr gram send --critical`). Until the app holds Apple's
            // critical-alerts entitlement and the owner allows it, iOS would show it as an
            // ordinary alert; time-sensitive at least breaks through Focus.
            if critical,
               await UNUserNotificationCenter.current().notificationSettings().criticalAlertSetting != .enabled {
                content.interruptionLevel = .timeSensitive
                content.sound = .default
            }
            self.finish(content)
        }
    }

    /// Out of time: deliver the push unchanged — it still opens the chat when tapped.
    override func serviceExtensionTimeWillExpire() {
        if let original { finish(original) }
    }

    private func finish(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    private static func register(_ category: AskCategory) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        let delivered = Set(await center.deliveredNotifications().map(\.request.content.categoryIdentifier))
        let keep = AskCategory.retained(existing: existing.map(\.identifier), delivered: delivered,
                                        adding: category.identifier)
        var categories = existing.filter { keep.contains($0.identifier) && $0.identifier != category.identifier }
        categories.insert(UNNotificationCategory(
            identifier: category.identifier,
            actions: category.actions.map {
                UNNotificationAction(identifier: $0.identifier, title: $0.title, options: [.authenticationRequired])
            },
            intentIdentifiers: [],
            options: []))
        center.setNotificationCategories(categories)
        // `setNotificationCategories` applies asynchronously with no completion, and a
        // notification shown before its category lands has no buttons. Reading the set back
        // waits for the write to be applied.
        _ = await center.notificationCategories()
    }
}
