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
    public static let catalog: [(id: String, title: String, question: String, symbol: String, multiline: Bool)] = [
        ("name", "Name", "What should Orbit call you?", "person.fill", false),
        ("timezone", "Time zone", "Choose", "globe.americas.fill", false),
        ("school", "School", "e.g. CMU, Computer Science", "graduationcap.fill", false),
        ("year", "Year", "Choose", "calendar", false),
        ("work", "Work", "Job or role, if any", "briefcase.fill", false),
        ("wake", "Wake up", "Add", "sunrise.fill", false),
        ("bedtime", "Bedtime", "Add", "moon.fill", false),
        ("routines", "Routines", "When you work, exercise, wind down", "clock.fill", true),
        ("goals", "Goals & interests", "What you’re working toward, what you enjoy", "star.fill", true),
        ("context", "Anything else", "Anything else Orbit should keep in mind", "text.alignleft", true),
    ]
    /// Ready-made choices for the fields that have them.
    public static let yearOptions = ["Freshman", "Sophomore", "Junior", "Senior", "Graduate student", "Not in school"]
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
