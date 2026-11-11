import Foundation
import Network

/// Minimal one-shot HTTP listener on 127.0.0.1 for the OAuth loopback redirect required by
/// Sign in with ChatGPT (`http://127.0.0.1:<port>/auth/callback`). It accepts the first request whose
/// path matches, replies with a small HTML page, and hands back the full callback URL.
public final class LoopbackServer: @unchecked Sendable {
    public static let callbackPath = "/auth/callback"
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "orbit.loopback")
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false
    private let preferredPorts: [UInt16]
    public private(set) var port: UInt16 = 0

    /// Prefers port 1455 (as in OpenAI's docs); only the port may vary between attempts.
    public init(preferredPorts: [UInt16] = [1455, 1456, 1457, 54321]) {
        self.preferredPorts = preferredPorts
    }

    public var redirectURI: String { "http://127.0.0.1:\(port)\(Self.callbackPath)" }

    /// Bind 127.0.0.1 on the first free preferred port; returns once ready (so the browser can't race it).
    public func start() async throws {
        var lastError: Error = URLError(.cannotConnectToHost)
        for p in preferredPorts + [0] {
            do {
                port = try await bind(p)
                return
            } catch { lastError = error }
        }
        throw lastError
    }

    private func bind(_ p: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p) ?? .any)
        let l = try NWListener(using: params)
        return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            // State updates arrive serially on `queue`; the box only guards against double-resume.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !once.done { once.done = true; self?.listener = l; ready.resume(returning: l.port?.rawValue ?? p) }
                case .failed(let e), .waiting(let e):
                    if !once.done { once.done = true; l.cancel(); ready.resume(throwing: e) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
        }
    }

    /// Wait for the redirect (or throw on timeout/cancel).
    public func waitForCallback(timeout: TimeInterval = 600) async throws -> URL {
        defer { stop() }
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                if self.finished { c.resume(throwing: CancellationError()); return }
                self.continuation = c
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(URLError(.timedOut))) }
            }
        }
    }

    public func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ r: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        continuation?.resume(with: r)
        continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", let url = URL(string: "http://127.0.0.1:\(self.port)\(parts[1])"),
                  url.path == Self.callbackPath else {
                self.reply(conn, status: "404 Not Found", body: "Not found")
                return
            }
            let ok = !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "error" } ?? false)
            self.reply(conn, status: "200 OK", body: ok ? "Signed in to Orbit. You can close this window and return to the app." : "Sign-in was not completed. You can close this window.")
            self.finish(.success(url))
        }
    }

    private func reply(_ conn: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>Orbit</title><body style='font:17px -apple-system,system-ui;margin:3rem'><p>\(body)</p>"
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(html)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}
