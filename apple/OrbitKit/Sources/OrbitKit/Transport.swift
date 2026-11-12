import Foundation

/// HTTP transport with a TCP fallback.
///
/// Cloudflare advertises HTTP/3, so URLSession may send requests over QUIC (UDP). On networks that drop
/// UDP — and in some iOS Simulator setups — the QUIC socket fails immediately and URLSession reports
/// "The network connection was lost" (-1005) instead of falling back to TCP — sometimes after the server
/// already received and acted on the request. So after any such failure, every later request in this
/// process goes over TCP on a fresh ephemeral session (no cached HTTP/3 hint). Only idempotent requests
/// (GET/HEAD/PUT/DELETE) are retried automatically; a POST is never resent, because its first attempt may
/// have succeeded (pairing codes are single-use; chat sends are retried by the user with the same id).
public enum Transport {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var preferTCP = false
    }
    private static let state = State()

    static var preferTCP: Bool {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.preferTCP }
        set { state.lock.lock(); state.preferTCP = newValue; state.lock.unlock() }
    }

    /// Errors where the request most likely never reached the server over a working connection.
    static func isTransportFailure(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(e.code)
    }

    static func freshSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func isIdempotent(_ request: URLRequest) -> Bool {
        ["GET", "HEAD", "PUT", "DELETE", "OPTIONS"].contains((request.httpMethod ?? "GET").uppercased())
    }

    public static func data(for request: URLRequest, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        if preferTCP {
            let s = freshSession()
            defer { s.finishTasksAndInvalidate() }
            return try await s.data(for: request)
        }
        do {
            return try await session.data(for: request)
        } catch where isTransportFailure(error) {
            preferTCP = true
            guard isIdempotent(request) else { throw error }
            let s = freshSession()
            defer { s.finishTasksAndInvalidate() }
            return try await s.data(for: request)
        }
    }

    /// Streaming variant. The returned session must stay alive while bytes are read; it is returned so the caller holds it.
    public static func bytes(for request: URLRequest, session: URLSession = .shared) async throws -> (URLSession.AsyncBytes, URLResponse, URLSession?) {
        if preferTCP {
            let s = freshSession()
            let (b, r) = try await s.bytes(for: request)
            return (b, r, s)
        }
        do {
            let (b, r) = try await session.bytes(for: request)
            return (b, r, nil)
        } catch where isTransportFailure(error) {
            preferTCP = true
            guard isIdempotent(request) else { throw error }
            let s = freshSession()
            let (b, r) = try await s.bytes(for: request)
            return (b, r, s)
        }
    }
}
