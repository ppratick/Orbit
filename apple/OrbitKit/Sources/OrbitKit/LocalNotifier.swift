#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// Local notifications for new Orbit notifications discovered by sync. These need no Apple Developer
/// Program membership (unlike APNs remote push). They fire while the app runs (always on the Mac companion;
/// on iPhone in the foreground or during opportunistic background refresh).
///
/// Approval notifications carry Approve / Deny actions handled by `OrbitAppModel`.
public enum LocalNotifier {
    public static let approvalCategory = "ORBIT_APPROVAL"
    public static let approveAction = "ORBIT_APPROVE"
    public static let denyAction = "ORBIT_DENY"

    public static func register() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let approve = UNNotificationAction(identifier: approveAction, title: "Approve", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: [])])
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    public static func post(_ items: [OrbitNotification]) {
        let center = UNUserNotificationCenter.current()
        for n in items.prefix(8) {
            let c = UNMutableNotificationContent()
            c.title = n.title
            c.body = n.body
            c.sound = .default
            c.threadIdentifier = n.category
            var info: [String: String] = ["notification_id": n.id]
            if let t = n.refType { info["ref_type"] = t }
            if let r = n.refId { info["ref_id"] = r }
            c.userInfo = info
            if n.category == "approval" { c.categoryIdentifier = approvalCategory }
            // Identifier = server id, so the same notification is never shown twice.
            center.add(UNNotificationRequest(identifier: n.id, content: c, trigger: nil))
        }
    }
}
#endif
