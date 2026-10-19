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
        static let cleanup = "auto-cleanup"
        static let info = "info"
    }

    enum Action {
        static let stop = "stop"
        static let ignore = "ignore"
        static let keep = "keep"
        /// Keep running and stop counting/cleaning them up (adds them to the ignore list).
        static let keepIgnore = "keep-ignore"
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
            UNNotificationCategory(identifier: Category.cleanup, actions: [
                UNNotificationAction(identifier: Action.stop, title: "Stop now", options: [.destructive]),
                UNNotificationAction(identifier: Action.keepIgnore, title: "Keep them", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.info, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            ActivityLog.write("notifications " + (granted ? "allowed" : "not allowed") + (error.map { " (\($0.localizedDescription))" } ?? ""))
        }
    }

    /// `refs` are what Stop kills; `signatures` are what Ignore / Keep hide.
    func post(id: String, title: String, body: String, category: String, refs: [PidRef], signature: String? = nil,
              signatures: [String] = []) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = [
            "refs": refs.map { [NSNumber(value: $0.pid), NSNumber(value: $0.start)] },
            "signatures": signatures + (signature.map { [$0] } ?? []),
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
        let signatures = info["signatures"] as? [String] ?? []
        completionHandler()
        Task { @MainActor in
            switch action {
            case Action.stop: Store.shared.stop(refs: refs)
            case Action.ignore, Action.keepIgnore: Store.shared.ignore(signatures: signatures)
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
