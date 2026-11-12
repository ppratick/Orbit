import Foundation

/// Server timestamps are integer milliseconds since the Unix epoch.
public typealias Millis = Int64
extension Millis {
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(self) / 1000) }
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var archived: Int
    public var createdAt: Millis
    public var updatedAt: Millis
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var conversationId: String?
    public var clientMsgId: String?
    public var role: String          // user | assistant | tool_call | tool_result | system
    public var content: String
    public var meta: JSONValue?
    public var createdAt: Millis
    public var isVisibleChat: Bool { role == "user" || role == "assistant" }

    public init(id: String, conversationId: String?, role: String, content: String, meta: JSONValue?, createdAt: Millis, clientMsgId: String? = nil) {
        self.id = id
        self.clientMsgId = clientMsgId
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.meta = meta
        self.createdAt = createdAt
    }
}

public struct OrbitTask: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var action: String
    public var target: String        // cloud | mac | iphone | apple
    public var status: String        // awaiting_approval | queued | leased | succeeded | failed | cancelled | denied
    public var summary: String
    public var params: JSONValue
    public var result: JSONValue?
    public var error: String?
    public var approvalId: String?
    public var conversationId: String?
    public var leaseDeviceId: String?
    public var attempts: Int
    public var createdAt: Millis
    public var updatedAt: Millis
    public var completedAt: Millis?
    /// Present only on tasks returned by the claim endpoint.
    public var leaseToken: String?
}

public struct Approval: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var taskId: String
    public var action: String
    public var summary: String
    public var status: String
    public var createdAt: Millis
    public var expiresAt: Millis
    public var params: JSONValue?
}

public struct Memory: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var content: String
    public var source: String
    public var sourceRef: String?
    public var createdAt: Millis
    public var updatedAt: Millis
    public var deletedAt: Millis?
}

/// One section of the user's "About you" profile. The user's text is authoritative.
public struct ProfileSection: Codable, Identifiable, Hashable, Sendable {
    public var id: String            // basics | work | people | routines | goals | context
    public var content: String
    public var updatedAt: Millis
    public var updatedBy: String?

    public init(id: String, content: String, updatedAt: Millis, updatedBy: String? = nil) {
        self.id = id; self.content = content; self.updatedAt = updatedAt; self.updatedBy = updatedBy
    }

    /// The fixed set of fields, in display order. Short fields hold one value; the rest are notes.
    /// The form's fields in display order: label, example placeholder, and whether it is a notes box.
    public static let catalog: [(id: String, title: String, question: String, symbol: String, multiline: Bool)] = [
        ("first_name", "First name", "e.g. Alex", "person.fill", false),
        ("last_name", "Last name", "e.g. Rivera", "person.fill", false),
        ("nickname", "What would you like Orbit to call you?", "e.g. Alex, or a nickname", "person.wave.2.fill", false),
        ("timezone", "Time zone", "Select your time zone", "globe.americas.fill", false),
        ("school", "School", "e.g. Carnegie Mellon University", "graduationcap.fill", false),
        ("major", "Major or program", "e.g. Computer Science", "book.fill", false),
        ("year", "Year", "Select", "calendar", false),
        ("work", "Work", "Select", "briefcase.fill", false),
        ("goals", "Goals & interests", "e.g. Land a summer internship, run a half marathon, learn piano", "star.fill", true),
        ("context", "Anything else Orbit should know", "e.g. I do my best work in the mornings", "text.alignleft", true),
    ]
    /// Ready-made choices for the fields that have them.
    public static let yearOptions = ["Freshman", "Sophomore", "Junior", "Senior", "Graduate student", "Not in school"]
    public static let workOptions = ["Student", "Part-time", "Full-time"]
    public static func title(for id: String) -> String { catalog.first { $0.id == id }?.title ?? id.capitalized }
}

/// A fact Orbit learned in conversation, waiting for the user to add it to their profile or dismiss it.
public struct ProfileSuggestion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var section: String
    public var content: String
    public var source: String
    public var sourceRef: String?
    public var status: String        // pending | accepted | dismissed
    public var createdAt: Millis
    public var updatedAt: Millis
}

public struct Responsibility: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String
    public var status: String
    public var notes: String
    public var dueAt: Millis?
    public var nextCheckAt: Millis?
    public var source: String
    public var createdAt: Millis
    public var updatedAt: Millis
}

public struct OrbitNotification: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var category: String
    public var refType: String?
    public var refId: String?
    public var readAt: Millis?
    public var createdAt: Millis
}

public struct Activity: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var summary: String
    public var taskId: String?
    public var createdAt: Millis
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: String
    public var label: String
    public var identity: String?
    public var status: String
    public var lastError: String?
    public var lastSyncAt: Millis?
}

public struct DeviceInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var lastSeenAt: Millis?
    public var revokedAt: Millis?
}

/// Incremental sync payload (GET /v1/sync).
public struct SyncResponse: Decodable, Sendable {
    public struct Changes: Decodable, Sendable {
        public var conversation: [Conversation]?
        public var message: [Message]?
        public var task: [OrbitTask]?
        public var approval: [Approval]?
        public var memory: [Memory]?
        public var profile: [ProfileSection]?
        public var profileSuggestion: [ProfileSuggestion]?
        public var responsibility: [Responsibility]?
        public var notification: [OrbitNotification]?
        public var activity: [Activity]?
        public var account: [Account]?
        public var device: [DeviceInfo]?
    }
    public var cursor: Int64
    public var reset: Bool
    public var hasMore: Bool
    public var changes: Changes
    public var deleted: [String: [String]]
}

public struct TurnResponse: Decodable, Sendable {
    public var userMessageId: String
    public var messages: [Message]
    public var replayed: Bool
}

/// "Answer details" for an Orbit reply: how many AI model calls produced it, with which models,
/// and when it finished. Recorded by the server in the reply's metadata; older replies have none.
public struct AnswerDetails: Equatable, Sendable {
    public struct ModelUse: Equatable, Sendable { public var model: String; public var calls: Int }
    /// nil when the reply predates call counting ("Unavailable").
    public var calls: Int?
    public var models: [ModelUse]
    public var breakdown: [(purpose: String, count: Int)]
    public var finishedAt: Date
    /// Posted by a device when a task finished, with no model involved.
    public var postedByDevice: Bool

    public static func == (a: AnswerDetails, b: AnswerDetails) -> Bool {
        a.calls == b.calls && a.models == b.models && a.finishedAt == b.finishedAt && a.postedByDevice == b.postedByDevice
            && a.breakdown.map(\.purpose) == b.breakdown.map(\.purpose) && a.breakdown.map(\.count) == b.breakdown.map(\.count)
    }

    /// Display order and wording for each kind of call.
    public static let purposeLabels: [(key: String, one: String, many: String)] = [
        ("answer", "answer", "answers"),
        ("toolFollowup", "after tool results", "after tool results"),
        ("steering", "follow-up check", "follow-up checks"),
        ("discarded", "discarded after your correction", "discarded after your corrections"),
        ("summary", "wrap-up summary", "wrap-up summaries"),
    ]

    public init?(message: Message) {
        guard message.role == "assistant", !message.id.hasPrefix("local-"), message.id != "streaming" else { return nil }
        let meta = message.meta
        postedByDevice = meta?["kind"]?.string == "task_result"
        if let usage = meta?["usage"], let n = usage["calls"]?.number {
            calls = Int(n)
            models = (usage["models"]?.array ?? []).compactMap { m in
                guard let id = m["model"]?.string else { return nil }
                return ModelUse(model: id, calls: Int(m["calls"]?.number ?? 0))
            }
            breakdown = Self.purposeLabels.compactMap { p in
                let raw = p.key == "toolFollowup" ? "tool_followup" : p.key
                guard let c = usage["breakdown"]?[raw]?.number, c > 0 else { return nil }
                return (p.key, Int(c))
            }
            finishedAt = usage["finished_at"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) } ?? message.createdAt.date
        } else {
            calls = nil
            // Older replies still recorded which model wrote them.
            models = meta?["model"]?.string.map { [ModelUse(model: $0, calls: 0)] } ?? []
            breakdown = []
            finishedAt = message.createdAt.date
        }
    }

    /// e.g. "1 answer · 1 after tool results · 1 follow-up check".
    public var breakdownText: String {
        breakdown.map { item in
            let label = Self.purposeLabels.first { $0.key == item.purpose }
            return "\(item.count) \(item.count == 1 ? label?.one ?? item.purpose : label?.many ?? item.purpose)"
        }.joined(separator: " · ")
    }
}
