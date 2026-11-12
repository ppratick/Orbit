import XCTest
@testable import OrbitKit

final class OrbitKitTests: XCTestCase {
    func testDecodesSyncPayloadWithSnakeCaseAndNestedParams() throws {
        let json = """
        {"cursor":42,"reset":false,"has_more":false,"deleted":{"message":["msg_x"]},
         "changes":{"task":[{"id":"task_1","action":"calendar.create_event","target":"apple","status":"queued","summary":"Add",
           "params":{"title":"Dentist","start":"2026-11-13T09:00:00-05:00","all_day":true},"result":null,"error":null,
           "approval_id":null,"conversation_id":"conv_1","lease_device_id":null,"attempts":0,"created_at":1,"updated_at":2,"completed_at":null}],
          "memory":[{"id":"mem_1","kind":"fact","content":"x","source":"user","source_ref":null,"created_at":1,"updated_at":1,"deleted_at":null}]}}
        """
        let r = try JSONDecoder.orbit.decode(SyncResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.cursor, 42)
        let t = try XCTUnwrap(r.changes.task?.first)
        // Snake-case keys inside arbitrary JSON are camel-cased by the decoder; lookups accept both.
        XCTAssertEqual(t.params["all_day"]?.bool, true)
        XCTAssertEqual(t.params["title"]?.string, "Dentist")
        XCTAssertEqual(r.deleted["message"], ["msg_x"])
    }

    func testDecodesAboutYouProfileAndSuggestionsFromSync() throws {
        let json = """
        {"cursor":7,"reset":false,"has_more":false,"deleted":{},
         "changes":{"profile":[{"id":"basics","content":"Sam","updated_at":5,"updated_by":"dev_1"}],
          "profile_suggestion":[{"id":"psug_1","section":"work","content":"Studies CS at CMU","source":"conversation","source_ref":"conv_orbit_primary","status":"pending","created_at":3,"updated_at":3}]}}
        """
        let r = try JSONDecoder.orbit.decode(SyncResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.changes.profile?.first?.content, "Sam")
        XCTAssertEqual(r.changes.profileSuggestion?.first?.section, "work")
        XCTAssertEqual(ProfileSection.catalog.map(\.id), ["first_name", "last_name", "nickname", "timezone", "school", "major", "year", "work", "goals", "context"])
    }

    func testAnswerDetailsParsesRecordedCountsAndMarksOlderRepliesUnavailable() throws {
        let json = """
        {"cursor":1,"reset":false,"has_more":false,"deleted":{},"changes":{"message":[
          {"id":"m1","conversation_id":"c","role":"assistant","content":"hi","created_at":1000,
           "meta":{"model":"gpt-6.1-sol","usage":{"calls":3,"models":[{"model":"gpt-6-luna","calls":1},{"model":"gpt-6.1-sol","calls":2}],
             "breakdown":{"answer":1,"tool_followup":1,"steering":1},"finished_at":5000}}},
          {"id":"m2","conversation_id":"c","role":"assistant","content":"old","created_at":2000,"meta":{"model":"gpt-6-luna"}},
          {"id":"m3","conversation_id":"c","role":"user","content":"q","created_at":900}]}}
        """
        let rows = try XCTUnwrap(JSONDecoder.orbit.decode(SyncResponse.self, from: Data(json.utf8)).changes.message)
        let d = try XCTUnwrap(AnswerDetails(message: rows[0]))
        XCTAssertEqual(d.calls, 3)
        XCTAssertEqual(d.models.map(\.calls), [1, 2])
        XCTAssertEqual(d.breakdownText, "1 answer · 1 after tool results · 1 follow-up check")
        XCTAssertEqual(d.finishedAt, Date(timeIntervalSince1970: 5))
        let old = try XCTUnwrap(AnswerDetails(message: rows[1]))
        XCTAssertNil(old.calls, "older replies show Unavailable")
        XCTAssertEqual(old.models.first?.model, "gpt-6-luna")
        XCTAssertNil(AnswerDetails(message: rows[2]), "only Orbit replies have details")
    }

    func testDecodesScheduleFromSync() throws {
        let json = """
        {"cursor":2,"reset":false,"has_more":false,"deleted":{},"changes":{"schedule":[{"id":"sch_1","title":"Inbox check","instructions":"Check mail",
          "repeat":"weekly","time_of_day":"07:45","days":"1,3","interval_hours":null,"run_at":null,"timezone":"America/New_York","respect_quiet_hours":1,
          "status":"active","next_run_at":5000,"last_run_at":null,"last_finished_at":null,"last_status":null,"last_result":null,"last_message_id":null,
          "run_count":0,"source":"conversation","created_at":1,"updated_at":1,"deleted_at":null}]}}
        """
        let s = try XCTUnwrap(JSONDecoder.orbit.decode(SyncResponse.self, from: Data(json.utf8)).changes.schedule?.first)
        XCTAssertEqual(s.repeat, "weekly")
        XCTAssertEqual(s.dayList, [1, 3])
        XCTAssertEqual(s.timeOfDay, "07:45")
    }

    @MainActor
    func testProfileEditsSurviveOfflineCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OrbitStore(directory: directory)
        store.upsert(profileSection: ProfileSection(id: "routines", content: "Gym at 7", updatedAt: 9))
        store.save()
        let restored = OrbitStore(directory: directory)
        XCTAssertEqual(restored.profileText("routines"), "Gym at 7")
        XCTAssertEqual(restored.profileText("goals"), "")
    }

    @MainActor
    func testOngoingHistorySurvivesOfflineCacheAndConversationRelocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OrbitStore(directory: directory)
        let original = Message(id: "original", conversationId: "old-chat", role: "user", content: "Keep this", meta: nil, createdAt: 1)
        let briefing = Message(id: "briefing", conversationId: "old-briefings", role: "assistant", content: "Today", meta: nil, createdAt: 2)
        store.upsert(messages: [original], conversationId: "old-chat")
        store.upsert(messages: [briefing], conversationId: "old-briefings")
        store.save()
        let restored = OrbitStore(directory: directory)
        XCTAssertEqual(restored.chat(OrbitStore.mainConversationId).map(\.id), ["original", "briefing"])
        var relocated = original
        relocated.conversationId = OrbitStore.mainConversationId
        restored.upsert(messages: [relocated], conversationId: OrbitStore.mainConversationId)
        XCTAssertEqual(restored.chat(OrbitStore.mainConversationId).count, 2, "Sync relocation must not duplicate or hide existing messages")
    }

    @MainActor
    func testServerAcknowledgementReplacesOptimisticMessageWhileReplyIsPending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OrbitStore(directory: directory)
        let conversation = OrbitStore.mainConversationId
        let local = Message(id: "local-send-1", conversationId: conversation, role: "user", content: "Check email", meta: nil, createdAt: 1, clientMsgId: "send-1")
        store.upsert(messages: [local], conversationId: conversation)
        let json = """
        {"id":"server-1","conversation_id":"conv_orbit_primary","role":"user","content":"Check email","meta":null,"created_at":2,"client_msg_id":"send-1"}
        """
        let acknowledged = try JSONDecoder.orbit.decode(Message.self, from: Data(json.utf8))
        store.upsert(messages: [acknowledged], conversationId: conversation)
        XCTAssertEqual(store.chat(conversation).map(\.id), ["server-1"])
        // Repeated sync or retry must not bring back the optimistic copy.
        store.upsert(messages: [local, acknowledged], conversationId: conversation)
        XCTAssertEqual(store.chat(conversation).map(\.id), ["server-1"])
        let repeated = Message(id: "local-send-2", conversationId: conversation, role: "user", content: "Check email", meta: nil, createdAt: 3, clientMsgId: "send-2")
        store.upsert(messages: [repeated], conversationId: conversation)
        XCTAssertEqual(store.chat(conversation).count, 2, "Identical text sent separately must remain separate")
    }

    func testISOParsing() {
        XCTAssertNotNil(ISO.parse("2026-11-13T09:00:00-05:00"))
        XCTAssertNotNil(ISO.parse("2026-11-13T14:00:00.123Z"))
        XCTAssertNil(ISO.parse("tomorrow"))
    }

    func testCamelCase() {
        XCTAssertEqual(JSONValue.camelCase("in_reply_to"), "inReplyTo")
        XCTAssertEqual(JSONValue.camelCase("title"), "title")
    }
}

final class SignInTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Example() {
        // RFC 7636 Appendix B test vector.
        XCTAssertEqual(ChatGPTSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLForNewAndReturningRegistration() throws {
        let cfg = APIClient.SignInConfig(authorizeUrl: "https://auth.openai.com/api/accounts/authorize", tokenUrl: "https://auth.openai.com/api/accounts/oauth/token",
                                         scopes: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", resource: "https://api.openai.com/v1", agentNameHint: "Orbit", registration: nil)
        func items(_ u: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let first = items(ChatGPTSignIn.authorizeURL(config: cfg, redirectURI: "http://127.0.0.1:1455/auth/callback", state: "s", nonce: "n", challenge: "c", hostId: "urn:uuid:x", saved: nil))
        XCTAssertEqual(first["client_id"], "dynamic_agent_client")
        XCTAssertEqual(first["agent_name_hint"], "Orbit")
        XCTAssertEqual(first["ext_agent_host_id"], "urn:uuid:x")
        XCTAssertEqual(first["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(first["code_challenge_method"], "S256")
        XCTAssertEqual(first["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(first["scope"], cfg.scopes)
        let again = items(ChatGPTSignIn.authorizeURL(config: cfg, redirectURI: "http://127.0.0.1:1456/auth/callback", state: "s", nonce: "n", challenge: "c", hostId: "urn:uuid:x",
                                                     saved: .init(clientId: "oaiapp_1", email: "a+b@example.com", idToken: "tok")))
        XCTAssertEqual(again["client_id"], "oaiapp_1")
        XCTAssertNil(again["agent_name_hint"], "omit agent_name_hint on reauthorization")
        XCTAssertEqual(again["id_token_hint"], "tok")
        XCTAssertEqual(again["login_hint"], "a+b@example.com", "plus sign survives encoding")
    }

    func testLoopbackServerReceivesCallback() async throws {
        let server = LoopbackServer(preferredPorts: [0])
        try await server.start()
        XCTAssertTrue(server.redirectURI.hasPrefix("http://127.0.0.1:"))
        async let callback = server.waitForCallback(timeout: 10)
        var req = URLRequest(url: URL(string: server.redirectURI + "?code=abc&state=xyz&client_id=oaiapp_9")!)
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Signed in to Orbit"))
        let url = try await callback
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value, "oaiapp_9")
    }

    func testParsesStreamEvents() throws {
        if case .reset? = try APIClient.parseEvent("reset", "{}") {} else { XCTFail() }
        if case .settled(let response)? = try APIClient.parseEvent("settled", #"{"user_message_id":"m","messages":[],"replayed":false}"#) {
            XCTAssertEqual(response.userMessageId, "m")
        } else { XCTFail() }
        if case .delta(let t)? = try APIClient.parseEvent("delta", #"{"text":"Hi"}"#) { XCTAssertEqual(t, "Hi") } else { XCTFail() }
        if case .tool(let n, let s)? = try APIClient.parseEvent("tool", #"{"name":"remember","state":"running"}"#) { XCTAssertEqual(n, "remember"); XCTAssertEqual(s, "running") } else { XCTFail() }
        XCTAssertThrowsError(try APIClient.parseEvent("error", #"{"code":"x","message":"boom"}"#))
        let done = try APIClient.parseEvent("done", #"{"user_message_id":"m","messages":[{"id":"a","role":"assistant","content":"ok","meta":null,"created_at":1}],"replayed":false}"#)
        if case .done(let r)? = done { XCTAssertEqual(r.messages.first?.content, "ok") } else { XCTFail() }
    }
}

final class PlainTextTests: XCTestCase {
    func testStripsMarkdownLikeTheServer() {
        XCTAssertEqual(PlainText.clean("## Today\n\n**Dentist** at 9am, bring your *card*.\n\n- Call Sam\n- Pay rent"),
                       "Today\n\nDentist at 9am, bring your card.\n\nCall Sam\nPay rent")
        XCTAssertEqual(PlainText.clean("Rate is 5 * 3 = 15, file my_notes_v2.txt"), "Rate is 5 * 3 = 15, file my_notes_v2.txt")
    }

    func testDetectsLinks() {
        let a = PlainText.attributed("Syllabus: https://canvas.example.edu/s")
        XCTAssertTrue(a.runs.contains { $0.link?.absoluteString == "https://canvas.example.edu/s" })
        XCTAssertEqual(String(a.characters), "Syllabus: https://canvas.example.edu/s")
    }
}

final class TransportTests: XCTestCase {
    func testOnlyIdempotentRequestsAreRetried() {
        var r = URLRequest(url: URL(string: "https://example.com")!)
        XCTAssertTrue(Transport.isIdempotent(r))
        r.httpMethod = "PUT"; XCTAssertTrue(Transport.isIdempotent(r))
        r.httpMethod = "POST"; XCTAssertFalse(Transport.isIdempotent(r), "pairing/chat POSTs must never be resent automatically")
    }

    func testClassifiesQUICLossAsTransportFailure() {
        XCTAssertTrue(Transport.isTransportFailure(URLError(.networkConnectionLost)))
        XCTAssertFalse(Transport.isTransportFailure(URLError(.notConnectedToInternet)))
        XCTAssertFalse(Transport.isTransportFailure(APIError(status: 400, code: "bad_code", message: "x")))
    }
}

final class AttachmentTests: XCTestCase {
    @MainActor func testFileOnlyMessageAndAttachmentReferencesSurviveOfflineCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ChatAttachment(id: "att_photo", name: "Photo.jpg", mime: "image/jpeg", size: 1024)
        let message = Message(id: "m_file", conversationId: "conv_file", role: "user", content: "", meta: .object(["attachments": .array([file.json])]), createdAt: 1)
        XCTAssertTrue(message.isVisibleChat)
        let store = OrbitStore(directory: directory)
        store.upsert(messages: [message], conversationId: "conv_file")
        store.save()
        let restored = OrbitStore(directory: directory)
        XCTAssertEqual(restored.messages[message.id]?.attachments, [file])
        XCTAssertTrue(try XCTUnwrap(restored.messages[message.id]?.attachments.first).isImage)
    }
}
