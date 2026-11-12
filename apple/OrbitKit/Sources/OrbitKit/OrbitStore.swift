import Foundation
import Combine

/// Local mirror of the server state, kept current by incremental sync and cached on disk so the app
/// opens instantly and works read-only offline. The server (D1) remains the source of truth.
@MainActor
public final class OrbitStore: ObservableObject {
    @Published public private(set) var conversations: [String: Conversation] = [:]
    @Published public private(set) var messages: [String: Message] = [:]
    @Published public private(set) var tasks: [String: OrbitTask] = [:]
    @Published public private(set) var approvals: [String: Approval] = [:]
    @Published public private(set) var memories: [String: Memory] = [:]
    @Published public private(set) var schedules: [String: Schedule] = [:]
    @Published public private(set) var profile: [String: ProfileSection] = [:]
    @Published public private(set) var profileSuggestions: [String: ProfileSuggestion] = [:]
    @Published public private(set) var responsibilities: [String: Responsibility] = [:]
    @Published public private(set) var notifications: [String: OrbitNotification] = [:]
    @Published public private(set) var activity: [String: Activity] = [:]
    @Published public private(set) var accounts: [String: Account] = [:]
    @Published public private(set) var devices: [String: DeviceInfo] = [:]
    @Published public private(set) var cursor: Int64 = 0
    @Published public var lastSyncError: String?
    @Published public private(set) var lastSyncAt: Date?

    /// Notifications that arrived through sync since launch (used to post local notifications once).
    public let newNotifications = PassthroughSubject<[OrbitNotification], Never>()

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cache.json")
        load()
    }

    // MARK: Derived views

    public static let mainConversationId = "conv_orbit_primary"

    public var sortedConversations: [Conversation] { conversations.values.filter { $0.archived == 0 }.sorted { $0.updatedAt > $1.updatedAt } }
    public func chat(_ conversationId: String) -> [Message] {
        messages.values.filter { (conversationId == Self.mainConversationId || $0.conversationId == conversationId) && $0.isVisibleChat }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    public var pendingApprovals: [Approval] { approvals.values.filter { $0.status == "pending" }.sorted { $0.createdAt > $1.createdAt } }
    public var recentTasks: [OrbitTask] { tasks.values.sorted { $0.updatedAt > $1.updatedAt } }
    public var liveMemories: [Memory] { memories.values.filter { $0.deletedAt == nil }.sorted { $0.updatedAt > $1.updatedAt } }
    public func profileText(_ section: String) -> String { profile[section]?.content ?? "" }
    public var pendingProfileSuggestions: [ProfileSuggestion] {
        profileSuggestions.values.filter { $0.status == "pending" }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    /// Active first (soonest next run), then paused, then finished.
    public var liveSchedules: [Schedule] {
        let rank = ["active": 0, "paused": 1, "done": 2]
        return schedules.values.filter { $0.deletedAt == nil }.sorted {
            (rank[$0.status] ?? 3, $0.nextRunAt ?? .max, $0.createdAt) < (rank[$1.status] ?? 3, $1.nextRunAt ?? .max, $1.createdAt)
        }
    }
    public func upsert(schedule: Schedule) { schedules[schedule.id] = schedule }
    public var openResponsibilities: [Responsibility] {
        responsibilities.values.filter { $0.status == "active" || $0.status == "waiting" }.sorted { ($0.dueAt ?? .max) < ($1.dueAt ?? .max) }
    }
    public var sortedNotifications: [OrbitNotification] { notifications.values.sorted { $0.createdAt > $1.createdAt } }
    public var sortedActivity: [Activity] { activity.values.sorted { $0.createdAt > $1.createdAt } }
    public var unreadCount: Int { notifications.values.filter { $0.readAt == nil }.count }

    // MARK: Sync

    /// Pull all pages of changes since the cursor. Safe to call often; it is cheap when nothing changed.
    public func sync(using api: APIClient) async {
        do {
            var fresh: [OrbitNotification] = []
            let firstSync = cursor == 0
            var pages = 0
            repeat {
                let r = try await api.sync(since: cursor)
                if r.reset { clear() }
                fresh += apply(r)
                cursor = r.cursor
                pages += 1
                if !r.hasMore { break }
            } while pages < 20
            lastSyncError = nil
            lastSyncAt = Date()
            save()
            // Don't flood the user with history on the very first sync of a new device.
            if !firstSync, !fresh.isEmpty { newNotifications.send(fresh) }
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    /// Merge locally-known rows immediately (e.g. the reply to a message the user just sent).
    public func upsert(messages new: [Message], conversationId: String) {
        var merged = messages
        for var m in new {
            if m.conversationId == nil { m.conversationId = conversationId }
            merged[m.id] = m
        }
        // Sync can acknowledge a send while its reply is still streaming. Replace the
        // optimistic row immediately, using identity rather than matching message text.
        for m in merged.values where !m.id.hasPrefix("local-") && m.role == "user" {
            if let clientId = m.clientMsgId { merged["local-\(clientId)"] = nil }
        }
        messages = merged
    }

    public func removeMessage(_ id: String) { messages[id] = nil }

    public func upsert(conversation: Conversation) { conversations[conversation.id] = conversation }

    private func apply(_ r: SyncResponse) -> [OrbitNotification] {
        let c = r.changes
        c.conversation?.forEach { conversations[$0.id] = $0 }
        if let rows = c.message { upsert(messages: rows, conversationId: Self.mainConversationId) }
        c.task?.forEach { tasks[$0.id] = $0 }
        c.approval?.forEach { a in
            // Sync rows omit params; keep any we fetched from /v1/approvals.
            var merged = a
            if merged.params == nil { merged.params = approvals[a.id]?.params }
            approvals[a.id] = merged
        }
        c.memory?.forEach { memories[$0.id] = $0 }
        c.schedule?.forEach { schedules[$0.id] = $0 }
        c.profile?.forEach { profile[$0.id] = $0 }
        c.profileSuggestion?.forEach { profileSuggestions[$0.id] = $0 }
        c.responsibility?.forEach { responsibilities[$0.id] = $0 }
        c.activity?.forEach { activity[$0.id] = $0 }
        c.account?.forEach { accounts[$0.id] = $0 }
        c.device?.forEach { devices[$0.id] = $0 }
        var fresh: [OrbitNotification] = []
        c.notification?.forEach { n in
            if notifications[n.id] == nil, n.readAt == nil { fresh.append(n) }
            notifications[n.id] = n
        }
        for (entity, ids) in r.deleted {
            for id in ids {
                switch entity {
                case "conversation": conversations[id] = nil
                case "message": messages[id] = nil
                case "account": accounts[id] = nil
                default: break
                }
            }
        }
        // Keep the cache bounded on the phone.
        if activity.count > 500 { activity = Dictionary(uniqueKeysWithValues: sortedActivity.prefix(300).map { ($0.id, $0) }) }
        return fresh
    }

    /// Apply the user's own edit right away; sync confirms it moments later.
    public func upsert(profileSection: ProfileSection) { profile[profileSection.id] = profileSection }
    public func resolveSuggestion(_ id: String, status: String) { profileSuggestions[id]?.status = status }

    public func mergeApprovalDetails(_ list: [Approval]) { list.forEach { approvals[$0.id] = $0 } }

    public func clear() {
        conversations = [:]; messages = [:]; tasks = [:]; approvals = [:]; memories = [:]
        profile = [:]; profileSuggestions = [:]; schedules = [:]
        responsibilities = [:]; notifications = [:]; activity = [:]; accounts = [:]; devices = [:]; cursor = 0
    }

    // MARK: Disk cache

    private struct Snapshot: Codable {
        var cursor: Int64
        var conversations: [Conversation]; var messages: [Message]; var tasks: [OrbitTask]; var approvals: [Approval]
        var memories: [Memory]; var responsibilities: [Responsibility]; var notifications: [OrbitNotification]
        var activity: [Activity]; var accounts: [Account]; var devices: [DeviceInfo]
        // Optional so caches written by older builds still load.
        var profile: [ProfileSection]?; var profileSuggestions: [ProfileSuggestion]?
        var schedules: [Schedule]?
    }

    public func save() {
        let s = Snapshot(cursor: cursor, conversations: Array(conversations.values), messages: Array(messages.values), tasks: Array(tasks.values),
                         approvals: Array(approvals.values), memories: Array(memories.values), responsibilities: Array(responsibilities.values),
                         notifications: Array(notifications.values), activity: Array(activity.values), accounts: Array(accounts.values), devices: Array(devices.values),
                         profile: Array(profile.values), profileSuggestions: Array(profileSuggestions.values),
                         schedules: Array(schedules.values))
        if let data = try? JSONEncoder().encode(s) {
            #if os(iOS)
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: fileURL, options: [.atomic])
            #endif
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        cursor = s.cursor
        conversations = Dictionary(s.conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        messages = Dictionary(s.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tasks = Dictionary(s.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        approvals = Dictionary(s.approvals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        memories = Dictionary(s.memories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        responsibilities = Dictionary(s.responsibilities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        notifications = Dictionary(s.notifications.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        activity = Dictionary(s.activity.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        accounts = Dictionary(s.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        devices = Dictionary(s.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        profile = Dictionary((s.profile ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        profileSuggestions = Dictionary((s.profileSuggestions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        schedules = Dictionary((s.schedules ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A cache from before these features existed never saw their rows: pull everything once.
        if s.profile == nil || s.schedules == nil { cursor = 0 }
    }
}
