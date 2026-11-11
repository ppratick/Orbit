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
        if case .delta(let t)? = try APIClient.parseEvent("delta", #"{"text":"Hi"}"#) { XCTAssertEqual(t, "Hi") } else { XCTFail() }
        if case .tool(let n, let s)? = try APIClient.parseEvent("tool", #"{"name":"remember","state":"running"}"#) { XCTAssertEqual(n, "remember"); XCTAssertEqual(s, "running") } else { XCTFail() }
        XCTAssertThrowsError(try APIClient.parseEvent("error", #"{"code":"x","message":"boom"}"#))
        let done = try APIClient.parseEvent("done", #"{"user_message_id":"m","messages":[{"id":"a","role":"assistant","content":"ok","meta":null,"created_at":1}],"replayed":false}"#)
        if case .done(let r)? = done { XCTAssertEqual(r.messages.first?.content, "ok") } else { XCTFail() }
    }
}
