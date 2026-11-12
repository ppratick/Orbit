import Foundation

public struct APIError: Error, LocalizedError, Sendable {
    public var status: Int
    public var code: String
    public var message: String
    public var errorDescription: String? { "\(message) (\(status))" }
}

/// Thin async client for the Orbit Worker. The device token comes from the Keychain;
/// no other credential is ever stored on the device.
public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    private struct ErrorBody: Decodable { struct E: Decodable { var code: String; var message: String }; var error: E }
    private struct Empty: Encodable {}

    func send<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil, as: T.Type = T.self, timeout: TimeInterval = 90) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder.orbit.encode(AnyEncodable(body))
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let e = try? JSONDecoder.orbit.decode(ErrorBody.self, from: data) {
                throw APIError(status: status, code: e.error.code, message: e.error.message)
            }
            throw APIError(status: status, code: "http", message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        if T.self == Data.self { return data as! T }
        return try JSONDecoder.orbit.decode(T.self, from: data)
    }

    // MARK: Pairing (no token needed)

    public struct Registration: Decodable, Sendable { public var deviceId: String; public var token: String }

    /// Redeem a one-time pairing code shown on another device (or created with the admin token).
    public static func redeem(baseURL: URL, code: String, name: String, kind: String) async throws -> Registration {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/devices/redeem"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.orbit.encode(["code": code, "name": name, "kind": kind])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 201 else {
            throw APIError(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, code: "pair", message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder.orbit.decode(Registration.self, from: data)
    }

    // MARK: Devices

    public struct PairingCode: Decodable, Sendable { public var code: String; public var expiresAt: Millis }
    public func createPairingCode() async throws -> PairingCode { try await send("POST", "v1/pairing-codes") }

    struct DeviceUpdate: Encodable { var name: String?; var capabilities: [String]?; var pushToken: String?; var pushEnv: String? }
    public func updateDevice(name: String? = nil, capabilities: [String]? = nil, pushToken: String? = nil, pushEnv: String? = nil) async throws {
        struct R: Decodable { var ok: Bool }
        _ = try await send("PUT", "v1/devices/me", body: DeviceUpdate(name: name, capabilities: capabilities, pushToken: pushToken, pushEnv: pushEnv), as: R.self)
    }

    // MARK: Sync & chat

    public func sync(since: Int64) async throws -> SyncResponse { try await send("GET", "v1/sync", query: ["since": String(since)]) }

    public func mainConversation() async throws -> Conversation {
        try await send("POST", "v1/conversation")
    }

    public func createConversation(id: String? = nil) async throws -> Conversation {
        try await send("POST", "v1/conversations", body: ["id": id ?? ""])
    }

    public func sendMessage(conversationId: String, content: String, clientMessageId: String) async throws -> TurnResponse {
        struct B: Encodable { var content: String; var clientMsgId: String }
        // Model turns with several tool calls can take a while.
        return try await send("POST", "v1/conversations/\(conversationId)/messages", body: B(content: content, clientMsgId: clientMessageId), timeout: 180)
    }

    public func archive(_ id: String) async throws { struct R: Decodable { var id: String }; _ = try await send("PATCH", "v1/conversations/\(id)", body: ["archived": true], as: R.self) }

    public func deleteConversation(_ id: String) async throws { struct R: Decodable { var ok: Bool }; _ = try await send("DELETE", "v1/conversations/\(id)", as: R.self) }

    public struct SearchHit: Decodable, Identifiable, Sendable { public var id: String; public var conversationId: String; public var title: String; public var snippet: String; public var createdAt: Millis }
    public func search(_ q: String) async throws -> [SearchHit] {
        struct R: Decodable { var results: [SearchHit] }
        return try await send("GET", "v1/search", query: ["q": q], as: R.self).results
    }

    // MARK: Approvals & tasks

    public func approvals() async throws -> [Approval] { struct R: Decodable { var approvals: [Approval] }; return try await send("GET", "v1/approvals", as: R.self).approvals }

    public func decide(approvalId: String, approve: Bool) async throws {
        struct R: Decodable { var task: OrbitTask }
        _ = try await send("POST", "v1/approvals/\(approvalId)/\(approve ? "approve" : "deny")", as: R.self)
    }

    public func cancel(taskId: String) async throws { struct R: Decodable { var ok: Bool }; _ = try await send("POST", "v1/tasks/\(taskId)/cancel", as: R.self) }

    public func claimTasks(limit: Int = 5) async throws -> [OrbitTask] {
        struct R: Decodable { var tasks: [OrbitTask] }
        return try await send("POST", "v1/device/tasks/claim", body: ["limit": limit], as: R.self).tasks
    }

    public func extendLease(taskId: String, leaseToken: String) async throws {
        struct R: Decodable { var ok: Bool }
        _ = try await send("POST", "v1/device/tasks/\(taskId)/extend", body: ["lease_token": leaseToken], as: R.self)
    }

    struct Completion: Encodable { var leaseToken: String; var ok: Bool; var result: JSONValue?; var error: String?; var retryable: Bool? }
    public func complete(taskId: String, leaseToken: String, result: Result<JSONValue, Error>, retryable: Bool = true) async throws {
        struct R: Decodable { var task: OrbitTask }
        let body: Completion
        switch result {
        case .success(let v): body = Completion(leaseToken: leaseToken, ok: true, result: v, error: nil, retryable: nil)
        case .failure(let e): body = Completion(leaseToken: leaseToken, ok: false, result: nil, error: e.localizedDescription, retryable: retryable)
        }
        _ = try await send("POST", "v1/device/tasks/\(taskId)/complete", body: body, as: R.self)
    }

    public func uploadContext(kind: String, items: [JSONValue]) async throws {
        struct B: Encodable { var kind: String; var items: [JSONValue] }
        struct R: Decodable { var ok: Bool }
        _ = try await send("PUT", "v1/device/context", body: B(kind: kind, items: items), as: R.self)
    }

    // MARK: Memory & responsibilities

    public func addMemory(kind: String, content: String) async throws { struct R: Decodable { var id: String }; _ = try await send("POST", "v1/memories", body: ["kind": kind, "content": content], as: R.self) }
    public func updateMemory(id: String, content: String) async throws { struct R: Decodable { var ok: Bool }; _ = try await send("PATCH", "v1/memories/\(id)", body: ["content": content], as: R.self) }
    public func deleteMemory(id: String) async throws { struct R: Decodable { var ok: Bool }; _ = try await send("DELETE", "v1/memories/\(id)", as: R.self) }
    public func setResponsibilityStatus(id: String, status: String) async throws { struct R: Decodable { var ok: Bool }; _ = try await send("PATCH", "v1/responsibilities/\(id)", body: ["status": status], as: R.self) }
    public func markRead(notificationId: String) async throws { struct R: Decodable { var ok: Bool }; _ = try await send("POST", "v1/notifications/\(notificationId)/read", as: R.self) }
    public func exportMarkdown() async throws -> Data { try await send("GET", "v1/export.md", as: Data.self) }

    // MARK: Accounts & model sign-in (credentials go straight to the Worker, which encrypts them)

    public struct LinkURL: Decodable, Sendable { public var url: String }
    public func googleLink(label: String) async throws -> LinkURL { try await send("POST", "v1/accounts/google/link", body: ["label": label]) }

    // Sign in with ChatGPT (dynamic client registration). Tokens are posted once to the Worker and never stored here.
    public struct SignInConfig: Decodable, Sendable {
        public struct Registration: Decodable, Sendable { public var clientId: String; public var email: String?; public var planUsage: Bool; public var status: String }
        public var authorizeUrl: String
        public var tokenUrl: String
        public var scopes: String
        public var resource: String
        public var agentNameHint: String
        public var registration: Registration?
        public init(authorizeUrl: String, tokenUrl: String, scopes: String, resource: String, agentNameHint: String, registration: Registration?) {
            self.authorizeUrl = authorizeUrl; self.tokenUrl = tokenUrl; self.scopes = scopes
            self.resource = resource; self.agentNameHint = agentNameHint; self.registration = registration
        }
    }
    public func chatgptConfig() async throws -> SignInConfig { try await send("GET", "v1/accounts/chatgpt/config") }

    public struct ImportResult: Decodable, Sendable { public var accountId: String; public var email: String?; public var planUsage: Bool }
    public func importChatGPT(clientId: String, nonce: String, tokens: ChatGPTSignIn.TokenResponse) async throws -> ImportResult {
        struct B: Encodable { var clientId: String; var nonce: String; var accessToken: String; var refreshToken: String?; var idToken: String; var expiresIn: Int?; var scope: String? }
        return try await send("POST", "v1/accounts/chatgpt/import", body: B(clientId: clientId, nonce: nonce, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, idToken: tokens.idToken, expiresIn: tokens.expiresIn, scope: tokens.scope))
    }
    public func chatgptSignOut() async throws -> Bool { struct R: Decodable { var revoked: Bool }; return try await send("POST", "v1/accounts/chatgpt/signout", as: R.self).revoked }

    public func connectICloud(username: String, appPassword: String) async throws { struct R: Decodable { var id: String }; _ = try await send("POST", "v1/accounts/icloud", body: ["username": username, "app_password": appPassword], as: R.self) }
    public func connectToken(provider: String, token: String, baseURL: String? = nil) async throws {
        struct R: Decodable { var id: String }
        var body = ["token": token]
        if let baseURL { body["base_url"] = baseURL }
        _ = try await send("POST", "v1/accounts/\(provider)", body: body, as: R.self)
    }
    public func disconnect(accountId: String) async throws { struct R: Decodable { var ok: Bool }; _ = try await send("DELETE", "v1/accounts/\(accountId)", as: R.self) }

    public struct ModelInfo: Decodable, Sendable {
        public struct Verified: Decodable, Sendable { public var basic: Bool; public var advanced: Bool }
        public struct CatalogModel: Decodable, Sendable, Identifiable { public var slug: String; public var displayName: String?; public var id: String { slug } }
        public var basicModel: String
        public var advancedModel: String
        public var authMode: String
        public var chatgptAccounts: [Account]
        public var verified: Verified?
        public var catalog: [CatalogModel]?
        public var verifyError: String?
    }
    public func modelInfo(verify: Bool = false) async throws -> ModelInfo { try await send("GET", "v1/model", query: verify ? ["verify": "1"] : [:]) }

    // MARK: Streaming chat

    public enum StreamEvent: Sendable {
        case status(model: String, step: Int)
        case delta(String)
        case tool(name: String, state: String)
        case done(TurnResponse)
    }

    /// Send a message and stream the reply (server-sent events). The final `.done` carries the stored
    /// messages — the source of truth — so a dropped stream can always be recovered by sync or by retrying
    /// with the same client message id.
    public func streamMessage(conversationId: String, content: String, clientMessageId: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    struct B: Encodable { var content: String; var clientMsgId: String }
                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/conversations/\(conversationId)/messages"), timeoutInterval: 300)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = try JSONEncoder.orbit.encode(B(content: content, clientMsgId: clientMessageId))
                    let (bytes, resp) = try await session.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 4000 { break } }
                        if let e = try? JSONDecoder.orbit.decode(ErrorBody.self, from: body) { throw APIError(status: status, code: e.error.code, message: e.error.message) }
                        throw APIError(status: status, code: "http", message: String(decoding: body, as: UTF8.self))
                    }
                    var event = "message"
                    var data = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                        else if line.hasPrefix("data:") { data += line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                        // `bytes.lines` drops blank separator lines, so dispatch as soon as a data line completes an event.
                        if !data.isEmpty, let parsed = try Self.parseEvent(event, data) {
                            if case .done = parsed { continuation.yield(parsed); continuation.finish(); return }
                            continuation.yield(parsed)
                            data = ""
                            event = "message"
                        }
                    }
                    throw APIError(status: 0, code: "stream_interrupted", message: "The reply stream ended early; it will appear after sync.")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parseEvent(_ event: String, _ data: String) throws -> StreamEvent? {
        let d = Data(data.utf8)
        switch event {
        case "delta":
            struct D: Decodable { var text: String }
            return .delta(try JSONDecoder.orbit.decode(D.self, from: d).text)
        case "tool":
            struct T: Decodable { var name: String; var state: String }
            let t = try JSONDecoder.orbit.decode(T.self, from: d)
            return .tool(name: t.name, state: t.state)
        case "status":
            struct S: Decodable { var model: String; var step: Int }
            let s = try JSONDecoder.orbit.decode(S.self, from: d)
            return .status(model: s.model, step: s.step)
        case "done":
            return .done(try JSONDecoder.orbit.decode(TurnResponse.self, from: d))
        case "error":
            struct E: Decodable { var code: String; var message: String }
            let e = try JSONDecoder.orbit.decode(E.self, from: d)
            throw APIError(status: 0, code: e.code, message: e.message)
        default:
            return nil
        }
    }
}

/// Type-erasing wrapper so `send` can take any Encodable body.
struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ v: any Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
