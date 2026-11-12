import CryptoKit
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Sign in with ChatGPT — OpenAI's official dynamic client registration for ChatGPT plan usage
/// (https://developers.openai.com/siwc/token-sharing-open-source/sign-in).
///
/// 1. Persist a stable per-device `ext_agent_host_id` (urn:uuid:…).
/// 2. Start a loopback listener on 127.0.0.1, generate fresh state, nonce and PKCE.
/// 3. Authorize with `client_id=dynamic_agent_client` + `agent_name_hint=Orbit` the first time, or the
///    saved issued client ID (+ id_token_hint/login_hint) afterwards.
/// 4. Exchange the code at the token endpoint (public client, no secret, `resource` included).
/// 5. Transfer the credential record to the Orbit Worker, which re-validates the ID token and from then on
///    owns refreshes. This device keeps only the issued client ID, email and ID token (for sign-in hints),
///    never the access/refresh tokens.
///
/// macOS opens the system browser. iOS uses an in-app ASWebAuthenticationSession so the app stays in the
/// foreground and its loopback listener can receive the redirect.
@MainActor
public final class ChatGPTSignIn: NSObject {
    public struct SavedRegistration: Codable, Sendable { public var clientId: String; public var email: String?; public var idToken: String? }

    public enum SignInError: LocalizedError {
        case declined, stateMismatch, missingClientId, clientIdMismatch, exchange(String), noPlanUsage
        public var errorDescription: String? {
            switch self {
            case .declined: return "Sign-in was cancelled or ChatGPT plan usage was declined."
            case .stateMismatch: return "Sign-in response did not match this attempt; try again."
            case .missingClientId: return "Registration did not return an issued client ID; try again."
            case .clientIdMismatch: return "Sign-in returned a different client registration than expected."
            case .exchange(let m): return "Token exchange failed: \(m)"
            case .noPlanUsage: return "Signed in, but ChatGPT plan usage wasn't allowed. Sign in again and allow it."
            }
        }
    }

    #if canImport(AuthenticationServices) && os(iOS)
    private var session: ASWebAuthenticationSession?
    #endif

    public override init() { super.init() }

    // MARK: Host ID & saved registration

    public static var hostId: String {
        if let id = KeychainStore.load(account: "siwc.host_id") { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        KeychainStore.save(id, account: "siwc.host_id")
        return id
    }

    public static var savedRegistration: SavedRegistration? {
        get { KeychainStore.load(account: "siwc.registration").flatMap { try? JSONDecoder().decode(SavedRegistration.self, from: Data($0.utf8)) } }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) { KeychainStore.save(String(decoding: d, as: UTF8.self), account: "siwc.registration") }
            else { KeychainStore.delete(account: "siwc.registration") }
        }
    }

    // MARK: PKCE helpers

    nonisolated static func randomURLSafe(_ bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URLEncoded
    }

    nonisolated static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    /// Build the authorization URL (exposed for tests).
    nonisolated static func authorizeURL(config: APIClient.SignInConfig, redirectURI: String, state: String, nonce: String, challenge: String, hostId: String, saved: SavedRegistration?) -> URL {
        var c = URLComponents(string: config.authorizeUrl)!
        var q: [URLQueryItem] = [
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: config.scopes),
            .init(name: "resource", value: config.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "ext_agent_host_id", value: hostId),
        ]
        if let saved {
            q.append(.init(name: "client_id", value: saved.clientId))
            if let hint = saved.idToken { q.append(.init(name: "id_token_hint", value: hint)) }
            if let email = saved.email { q.append(.init(name: "login_hint", value: email)) }
        } else {
            q.append(.init(name: "client_id", value: "dynamic_agent_client"))
            q.append(.init(name: "agent_name_hint", value: config.agentNameHint))
        }
        c.queryItems = q
        // URLComponents leaves "+" unescaped; encode it so scopes/values survive form decoding.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    // MARK: Flow

    /// Runs the full sign-in and hands the credentials to the Worker. Returns the signed-in email.
    @discardableResult
    public func signIn(api: APIClient, forceNewRegistration: Bool = false) async throws -> String? {
        let config = try await api.chatgptConfig()
        // Reuse this account's issued client ID if we (or another of the user's devices) registered before.
        var saved = forceNewRegistration ? nil : Self.savedRegistration
        if saved == nil, !forceNewRegistration, let reg = config.registration {
            saved = SavedRegistration(clientId: reg.clientId, email: reg.email, idToken: nil)
        }
        let server = LoopbackServer()
        try await server.start()
        let state = Self.randomURLSafe(), nonce = Self.randomURLSafe(), verifier = Self.randomURLSafe(48)
        let url = Self.authorizeURL(config: config, redirectURI: server.redirectURI, state: state, nonce: nonce,
                                    challenge: Self.challenge(for: verifier), hostId: Self.hostId, saved: saved)
        try await present(url, server: server)
        let callback = try await server.waitForCallback()
        dismiss()

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard value("state") == state else { throw SignInError.stateMismatch }
        if value("error") != nil { throw SignInError.declined }
        guard let code = value("code") else { throw SignInError.declined }
        let issuedClientId: String
        if let saved {
            if let cb = value("client_id"), cb != saved.clientId { throw SignInError.clientIdMismatch }
            issuedClientId = saved.clientId
        } else {
            guard let cb = value("client_id"), cb != "dynamic_agent_client" else { throw SignInError.missingClientId }
            issuedClientId = cb
        }

        let tokens = try await exchange(config: config, clientId: issuedClientId, code: code, verifier: verifier, redirectURI: server.redirectURI)
        let result = try await api.importChatGPT(clientId: issuedClientId, nonce: nonce, tokens: tokens)
        // Keep only what's needed for future sign-in hints; tokens now live (encrypted) in the Worker.
        Self.savedRegistration = SavedRegistration(clientId: issuedClientId, email: result.email, idToken: tokens.idToken)
        if !result.planUsage { throw SignInError.noPlanUsage }
        return result.email
    }

    public struct TokenResponse: Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var idToken: String
        public var expiresIn: Int?
        public var scope: String?
    }

    private func exchange(config: APIClient.SignInConfig, clientId: String, code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: config.tokenUrl)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Self.formEncode([
            "grant_type": "authorization_code", "client_id": clientId, "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI, "resource": config.resource,
        ])
        let (data, resp) = try await Transport.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SignInError.exchange(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder.orbit.decode(TokenResponse.self, from: data)
    }

    nonisolated static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return Data(s.utf8)
    }

    private func present(_ url: URL, server: LoopbackServer) async throws {
        #if os(macOS)
        NSWorkspace.shared.open(url) // system browser, per OpenAI's guidance
        #elseif os(iOS)
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "orbit-loopback-unused") { _, error in
            // The redirect goes to our loopback listener, not this scheme; a cancel here means the user closed the sheet.
            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { server.stop() }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        _ = s.start()
        #endif
    }

    private func dismiss() {
        #if os(iOS)
        session?.cancel()
        session = nil
        #endif
    }
}

#if os(iOS)
extension ChatGPTSignIn: ASWebAuthenticationPresentationContextProviding {
    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
#endif

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
