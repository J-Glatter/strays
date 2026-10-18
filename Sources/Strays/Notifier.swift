import AppKit
import StraysCore
import UserNotifications

/// macOS notifications with Stop / Ignore buttons. The first one triggers the system's
/// "Strays would like to send notifications" prompt.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Category {
        static let hot = "hot-stray"
        static let leftovers = "session-leftovers"
    }

    enum Action {
        static let stop = "stop"
        static let ignore = "ignore"
        static let keep = "keep"
    }

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.hot, actions: [
                UNNotificationAction(identifier: Action.stop, title: "Stop it", options: [.destructive]),
                UNNotificationAction(identifier: Action.ignore, title: "Ignore it", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.leftovers, actions: [
                UNNotificationAction(identifier: Action.stop, title: "Stop them", options: [.destructive]),
                UNNotificationAction(identifier: Action.keep, title: "Keep running", options: []),
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            ActivityLog.write("notifications " + (granted ? "allowed" : "not allowed") + (error.map { " (\($0.localizedDescription))" } ?? ""))
        }
    }

    /// `refs` are what Stop kills; `signature` is what Ignore hides.
    func post(id: String, title: String, body: String, category: String, refs: [PidRef], signature: String? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = [
            "refs": refs.map { [NSNumber(value: $0.pid), NSNumber(value: $0.start)] },
            "signature": signature ?? "",
        ]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            ActivityLog.write("notified: \(title) — \(body)" + (error.map { " [failed: \($0.localizedDescription)]" } ?? ""))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let refs = (info["refs"] as? [[NSNumber]] ?? []).compactMap { pair in
            pair.count == 2 ? PidRef(pid: pair[0].int32Value, start: pair[1].uint64Value) : nil
        }
        let signature = info["signature"] as? String ?? ""
        completionHandler()
        Task { @MainActor in
            switch action {
            case Action.stop: Store.shared.stop(refs: refs)
            case Action.ignore where !signature.isEmpty: Store.shared.ignore(signature: signature)
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
