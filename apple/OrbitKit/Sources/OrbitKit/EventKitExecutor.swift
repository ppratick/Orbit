import Foundation
#if canImport(EventKit)
import EventKit

/// Apple Calendar & Reminders through EventKit — the only supported programmatic access to
/// Reminders (iCloud Reminders are not reachable over CalDAV), and the reason these actions are
/// routed to a Mac or iPhone rather than the cloud.
///
/// Idempotency: every item Orbit creates carries `orbit://task/<task id>` in its URL; before creating,
/// we look for an existing item with that marker so a retried task never duplicates.
public final class EventKitExecutor: DeviceExecutor, @unchecked Sendable {
    public let actions = ["calendar.create_event", "calendar.update_event", "calendar.delete_event", "reminders.create", "reminders.complete"]
    private let store = EKEventStore()
    private let orbitCalendarName: String

    public init(orbitCalendarName: String = "Orbit") { self.orbitCalendarName = orbitCalendarName }

    // MARK: Permissions

    public func requestAccess() async -> (events: Bool, reminders: Bool) {
        let e = (try? await store.requestFullAccessToEvents()) ?? false
        let r = (try? await store.requestFullAccessToReminders()) ?? false
        return (e, r)
    }

    public static var eventsAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    public static var remindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    // MARK: Execute

    public func execute(_ task: OrbitTask) async throws -> JSONValue {
        let p = task.params
        switch task.action {
        case "calendar.create_event": return try createEvent(task, p)
        case "calendar.update_event": return try updateEvent(p)
        case "calendar.delete_event": return try deleteEvent(p)
        case "reminders.create": return try await createReminder(task, p)
        case "reminders.complete": return try await completeReminder(p)
        default: throw ExecutorError("Unsupported action \(task.action)")
        }
    }

    private func marker(_ task: OrbitTask) -> URL { URL(string: "orbit://task/\(task.id)")! }

    private func requireEvents() throws {
        guard Self.eventsAuthorized else { throw ExecutorError("Calendar access not granted on this device (Settings → Privacy → Calendars)") }
    }
    private func requireReminders() throws {
        guard Self.remindersAuthorized else { throw ExecutorError("Reminders access not granted on this device (Settings → Privacy → Reminders)") }
    }

    func orbitCalendar() throws -> EKCalendar {
        if let c = store.calendars(for: .event).first(where: { $0.title == orbitCalendarName && $0.allowsContentModifications }) { return c }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = orbitCalendarName
        // Prefer the account that holds the default calendar (usually iCloud) so the calendar syncs to all devices.
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .calDAV }) ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw ExecutorError("No calendar account available to create the \(orbitCalendarName) calendar")
        }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    private func calendar(named name: String?) throws -> EKCalendar {
        guard let name, !name.isEmpty, name != orbitCalendarName else { return try orbitCalendar() }
        guard let c = store.calendars(for: .event).first(where: { $0.title == name && $0.allowsContentModifications }) else {
            throw ExecutorError("Calendar \"\(name)\" not found or read-only")
        }
        return c
    }

    private func createEvent(_ task: OrbitTask, _ p: JSONValue) throws -> JSONValue {
        try requireEvents()
        guard let title = p["title"]?.string, let start = ISO.parse(p["start"]?.string) else { throw ExecutorError("title and a valid ISO start are required") }
        let allDay = p["all_day"]?.bool ?? false
        let end = ISO.parse(p["end"]?.string) ?? start.addingTimeInterval(allDay ? 86_400 : 3_600)
        let cal = try calendar(named: p["calendar"]?.string)
        // Idempotency check around the requested time.
        let existing = store.events(matching: store.predicateForEvents(withStart: start.addingTimeInterval(-86_400), end: end.addingTimeInterval(86_400), calendars: [cal]))
            .first { $0.url == marker(task) }
        if let e = existing { return .object(["event_id": .string(e.eventIdentifier ?? ""), "deduplicated": .bool(true)]) }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = end
        e.isAllDay = allDay
        e.location = p["location"]?.string
        e.notes = p["notes"]?.string
        e.calendar = cal
        e.url = marker(task)
        try store.save(e, span: .thisEvent, commit: true)
        return .object(["event_id": .string(e.eventIdentifier ?? ""), "calendar": .string(cal.title)])
    }

    private func updateEvent(_ p: JSONValue) throws -> JSONValue {
        try requireEvents()
        guard let id = p["event_id"]?.string, let e = store.event(withIdentifier: id) else { throw ExecutorError("Event not found") }
        let c = p["changes"] ?? .object([:])
        if let t = c["title"]?.string { e.title = t }
        if let s = ISO.parse(c["start"]?.string) {
            let duration = e.endDate.timeIntervalSince(e.startDate)
            e.startDate = s
            e.endDate = ISO.parse(c["end"]?.string) ?? s.addingTimeInterval(duration)
        } else if let en = ISO.parse(c["end"]?.string) { e.endDate = en }
        if let l = c["location"]?.string { e.location = l }
        if let n = c["notes"]?.string { e.notes = n }
        try store.save(e, span: .thisEvent, commit: true)
        return .object(["event_id": .string(id), "updated": .bool(true)])
    }

    private func deleteEvent(_ p: JSONValue) throws -> JSONValue {
        try requireEvents()
        guard let id = p["event_id"]?.string else { throw ExecutorError("event_id required") }
        guard let e = store.event(withIdentifier: id) else { return .object(["event_id": .string(id), "already_deleted": .bool(true)]) }
        try store.remove(e, span: .thisEvent, commit: true)
        return .object(["event_id": .string(id), "deleted": .bool(true)])
    }

    private func reminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func createReminder(_ task: OrbitTask, _ p: JSONValue) async throws -> JSONValue {
        try requireReminders()
        guard let title = p["title"]?.string else { throw ExecutorError("title required") }
        var list = store.defaultCalendarForNewReminders()
        if let name = p["list"]?.string, !name.isEmpty {
            guard let l = store.calendars(for: .reminder).first(where: { $0.title == name }) else { throw ExecutorError("Reminders list \"\(name)\" not found") }
            list = l
        }
        guard let target = list else { throw ExecutorError("No default Reminders list") }
        let open = await reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [target]))
        if let r = open.first(where: { $0.url == marker(task) }) {
            return .object(["reminder_id": .string(r.calendarItemIdentifier), "deduplicated": .bool(true)])
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = p["notes"]?.string
        r.calendar = target
        r.url = marker(task)
        if let due = ISO.parse(p["due"]?.string) {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        return .object(["reminder_id": .string(r.calendarItemIdentifier), "list": .string(target.title)])
    }

    private func completeReminder(_ p: JSONValue) async throws -> JSONValue {
        try requireReminders()
        guard let id = p["reminder_id"]?.string, let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ExecutorError("Reminder not found") }
        if !r.isCompleted {
            r.isCompleted = true
            try store.save(r, commit: true)
        }
        return .object(["reminder_id": .string(id), "completed": .bool(true)])
    }

    // MARK: Context snapshot for the cloud assistant

    public func calendarSnapshot(days: Int = 14) -> [JSONValue] {
        guard Self.eventsAuthorized else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(TimeInterval(days) * 86_400)
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).prefix(250).map { e in
            .object([
                "id": .string(e.eventIdentifier ?? ""), "title": .string(e.title ?? ""), "start": .string(ISO.format(e.startDate)),
                "end": .string(ISO.format(e.endDate)), "all_day": .bool(e.isAllDay), "calendar": .string(e.calendar.title),
                "location": e.location.map { .string($0) } ?? .null,
            ])
        }
    }

    public func remindersSnapshot() async -> [JSONValue] {
        guard Self.remindersAuthorized else { return [] }
        let list = await reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        return list.prefix(250).map { r in
            .object([
                "id": .string(r.calendarItemIdentifier), "title": .string(r.title ?? ""), "list": .string(r.calendar.title),
                "due": r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { .string(ISO.format($0)) } ?? .null,
            ])
        }
    }
}
#endif

/// ISO-8601 helpers matching the Worker's date-time format.
public enum ISO {
    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
    public static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }
}
