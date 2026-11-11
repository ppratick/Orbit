#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Sign in with ChatGPT" for Orbit's model access, using the user's own registered OAuth client.
///
/// The Worker creates the PKCE verifier/challenge and state, and performs the code exchange, so the
/// device never sees the verifier or any OpenAI tokens. The device only shows the authorization page
/// and returns the redirect URL it captured. This works when the client's registered redirect URI uses
/// a custom scheme (e.g. `orbit://oauth/chatgpt`). If the redirect URI points at the Worker
/// (`https://…/oauth/chatgpt/callback`), the Worker completes sign-in itself and this session simply
/// closes when the user is done.
@MainActor
public final class ChatGPTSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    public func signIn(api: APIClient) async throws {
        let link = try await api.chatgptLink()
        guard let url = URL(string: link.url) else { throw ExecutorError("Invalid authorization URL") }
        let redirect = link.redirectUri.flatMap(URL.init(string:))
        let scheme = redirect?.scheme.flatMap { ["http", "https"].contains($0) ? nil : $0 }
        let callback: URL? = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin, scheme == nil { cont.resume(returning: nil) } // Worker-handled redirect
                else { cont.resume(throwing: error ?? ExecutorError("Sign-in failed")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            if !s.start() { cont.resume(throwing: ExecutorError("Could not start sign-in")) }
        }
        if let callback { try await api.chatgptComplete(callbackURL: callback) }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #endif
    }
}
#endif
