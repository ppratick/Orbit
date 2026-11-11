import Combine
import Foundation
import OrbitKit
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// App-wide state shared by the iPhone and Mac apps: pairing, sync loop, device task execution,
/// chat sending (idempotent retries), approvals and local notifications.
@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @Published private(set) var isPaired = false
    @Published var sending: Set<String> = []          // conversation ids with a turn in flight
    @Published var failedSend: [String: (text: String, clientId: String)] = [:]
    @Published var banner: String?
    @Published var modelInfo: APIClient.ModelInfo?
    /// Live text of a reply that is still streaming, per conversation.
    @Published var streaming: [String: String] = [:]
    /// Short progress line while a turn runs ("Using remember…", model name).
    @Published var turnStatus: [String: String] = [:]

    let store = OrbitStore()
    private(set) var api: APIClient?
    private var runner: TaskRunner?
    private var loop: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var lastContextUpload = Date.distantPast
    #if canImport(EventKit)
    let eventKit = EventKitExecutor()
    #endif
    #if os(macOS)
    let mac = MacExecutor()
    static let deviceKind = "mac"
    #else
    static let deviceKind = "iphone"
    #endif

    override init() {
        super.init()
        if let token = KeychainStore.load(account: "token"), let url = URL(string: serverURL), !serverURL.isEmpty {
            configure(url: url, token: token)
        }
        store.newNotifications.sink { LocalNotifier.post($0) }.store(in: &cancellables)
        UNUserNotificationCenter.current().delegate = self
    }

    private func configure(url: URL, token: String) {
        let api = APIClient(baseURL: url, token: token)
        self.api = api
        var executors: [DeviceExecutor] = []
        #if canImport(EventKit)
        executors.append(eventKit)
        #endif
        #if os(macOS)
        executors.append(mac)
        #endif
        runner = TaskRunner(api: api, executors: executors)
        isPaired = true
    }

    // MARK: Pairing

    /// Pair with a one-time code from another Orbit device, or (first device) with the admin token.
    func pair(server: String, code: String, adminToken: String, name: String) async {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            banner = "Enter the Worker URL (https://…)"
            return
        }
        do {
            var token: String
            if !adminToken.isEmpty {
                // Admin token is used once to mint a pairing code and is never stored.
                let admin = APIClient(baseURL: url, token: adminToken)
                let code = try await admin.createPairingCode()
                token = try await APIClient.redeem(baseURL: url, code: code.code, name: name, kind: Self.deviceKind).token
            } else {
                token = try await APIClient.redeem(baseURL: url, code: code, name: name, kind: Self.deviceKind).token
            }
            KeychainStore.save(token, account: "token")
            UserDefaults.standard.set(trimmed, forKey: "serverURL")
            serverURL = trimmed
            store.clear()
            configure(url: url, token: token)
            start()
        } catch {
            banner = "Pairing failed: \(error.localizedDescription)"
        }
    }

    func unpair() {
        loop?.cancel()
        KeychainStore.delete(account: "token")
        api = nil
        runner = nil
        store.clear()
        store.save()
        isPaired = false
    }

    // MARK: Background loop

    func start() {
        guard isPaired, loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            _ = await LocalNotifier.register()
            #if canImport(EventKit)
            _ = await self.eventKit.requestAccess()
            #endif
            await self.registerCapabilities()
            await self.refreshModelInfo()
            while !Task.isCancelled {
                await self.tick()
                // Mac companion polls steadily; iPhone polls only while the app is active (iOS suspends it otherwise).
                try? await Task.sleep(nanoseconds: (Self.deviceKind == "mac" ? 20 : 15) * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One sync + work cycle. Also used by iOS background refresh.
    func tick() async {
        guard let api else { return }
        await store.sync(using: api)
        if let runner, await runner.drain() > 0 { await store.sync(using: api) }
        if Date().timeIntervalSince(lastContextUpload) > 15 * 60 { await uploadContext() }
    }

    func registerCapabilities() async {
        guard let api, let runner else { return }
        var caps = runner.capabilities
        #if os(macOS)
        caps += MacExecutor.allowListedScripts().map { "script:\($0)" }
        #endif
        try? await api.updateDevice(name: DeviceName.current, capabilities: caps)
    }

    /// Share the next two weeks of Apple Calendar and open Reminders with the cloud assistant.
    func uploadContext() async {
        #if canImport(EventKit)
        guard let api else { return }
        lastContextUpload = Date()
        if EventKitExecutor.eventsAuthorized { try? await api.uploadContext(kind: "calendar", items: eventKit.calendarSnapshot()) }
        if EventKitExecutor.remindersAuthorized { try? await api.uploadContext(kind: "reminders", items: await eventKit.remindersSnapshot()) }
        #endif
    }

    func refreshModelInfo(verify: Bool = false) async {
        guard let api else { return }
        do { modelInfo = try await api.modelInfo(verify: verify) } catch { if verify { banner = error.localizedDescription } }
    }

    // MARK: Chat

    func newConversation() async -> String? {
        guard let api else { return nil }
        do {
            let c = try await api.createConversation()
            store.upsert(conversation: c)
            return c.id
        } catch {
            banner = error.localizedDescription
            return nil
        }
    }

    /// Sends a message. The client message id makes retries safe: the server replays the stored reply
    /// instead of re-running the turn (no duplicate drafts/tasks after a dropped connection).
    func send(_ text: String, in conversationId: String, clientId: String = UUID().uuidString) async {
        guard let api, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        failedSend[conversationId] = nil
        let local = Message(id: "local-\(clientId)", conversationId: conversationId, role: "user", content: text, meta: nil, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        store.upsert(messages: [local], conversationId: conversationId)
        sending.insert(conversationId)
        streaming[conversationId] = ""
        defer {
            sending.remove(conversationId)
            streaming[conversationId] = nil
            turnStatus[conversationId] = nil
        }
        do {
            var final: TurnResponse?
            for try await event in api.streamMessage(conversationId: conversationId, content: text, clientMessageId: clientId) {
                switch event {
                case .delta(let d): streaming[conversationId, default: ""] += d
                case .status(let model, _): turnStatus[conversationId] = Self.modelLabel(model)
                case .tool(let name, let state):
                    if state == "running" {
                        streaming[conversationId] = "" // text before a tool call was a preamble; the final answer follows
                        turnStatus[conversationId] = "Using \(name.replacingOccurrences(of: "_", with: " "))…"
                    }
                case .done(let r): final = r
                }
            }
            if let r = final { store.upsert(messages: r.messages, conversationId: conversationId) }
            await store.sync(using: api) // brings the server copy of the user message
            store.removeMessage(local.id)
        } catch {
            // Retrying with the same client id is safe: the server replays a finished turn instead of re-running it.
            failedSend[conversationId] = (text, clientId)
            banner = "Not sent: \(error.localizedDescription)"
        }
    }

    static func modelLabel(_ id: String) -> String {
        if id.contains("luna") { return "Luna" }
        if id.contains("sol") { return "Sol" }
        return id
    }

    func retry(in conversationId: String) async {
        guard let f = failedSend[conversationId] else { return }
        await send(f.text, in: conversationId, clientId: f.clientId)
    }

    // MARK: Approvals & actions

    func loadApprovalDetails() async {
        guard let api, let list = try? await api.approvals() else { return }
        store.mergeApprovalDetails(list)
    }

    func decide(_ approvalId: String, approve: Bool) async {
        guard let api else { return }
        do {
            try await api.decide(approvalId: approvalId, approve: approve)
            await store.sync(using: api)
            if let runner { await runner.drain() } // if this device can run it, do it now
            await store.sync(using: api)
        } catch {
            banner = error.localizedDescription
        }
    }

    func perform(_ op: @escaping (APIClient) async throws -> Void) async {
        guard let api else { return }
        do {
            try await op(api)
            await store.sync(using: api)
        } catch {
            banner = error.localizedDescription
        }
    }
}

extension AppModel: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let refId = info["ref_id"] as? String, (info["ref_type"] as? String) == "approval" else { return }
        switch response.actionIdentifier {
        case LocalNotifier.approveAction: await decide(refId, approve: true)
        case LocalNotifier.denyAction: await decide(refId, approve: false)
        default: break
        }
    }
}

enum DeviceName {
    static var current: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }
}
