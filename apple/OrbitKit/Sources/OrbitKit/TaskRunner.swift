import Foundation

/// Something that can execute device-routed Orbit actions (EventKit, Mac files/scripts, ...).
public protocol DeviceExecutor: Sendable {
    /// Action names this executor handles, e.g. "calendar.create_event". Advertised to the server as capabilities.
    var actions: [String] { get }
    /// Execute an already-authorised task. Implementations must be idempotent per `task.id`
    /// (a retry after a lost completion must not create a second event/file).
    func execute(_ task: OrbitTask) async throws -> JSONValue
}

public struct ExecutorError: Error, LocalizedError, Sendable {
    public var message: String
    /// false → the server should not retry (e.g. permission denied, bad input).
    public var retryable: Bool
    public init(_ message: String, retryable: Bool = false) { self.message = message; self.retryable = retryable }
    public var errorDescription: String? { message }
}

/// Pulls work leased to this device, runs it, and reports back. The server guarantees each task is
/// leased to one device at a time; we extend the lease while long work runs, and a completion from a
/// stale lease is rejected server-side, so retries and device hand-offs cannot double-complete.
public actor TaskRunner {
    private let api: APIClient
    private let executors: [String: DeviceExecutor]
    private var running = false

    public init(api: APIClient, executors: [DeviceExecutor]) {
        self.api = api
        var map: [String: DeviceExecutor] = [:]
        for e in executors { for a in e.actions { map[a] = e } }
        self.executors = map
    }

    public nonisolated var capabilities: [String] { Array(executors.keys).sorted() }

    /// Claim and run whatever is queued for this device. Returns the number of tasks processed.
    @discardableResult
    public func drain(maxRounds: Int = 3) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }
        var processed = 0
        for _ in 0..<maxRounds {
            guard let tasks = try? await api.claimTasks(limit: 5), !tasks.isEmpty else { break }
            for task in tasks {
                await run(task)
                processed += 1
            }
        }
        return processed
    }

    private func run(_ task: OrbitTask) async {
        guard let lease = task.leaseToken else { return }
        guard let exec = executors[task.action] else {
            try? await api.complete(taskId: task.id, leaseToken: lease, result: .failure(ExecutorError("This device cannot run \(task.action)")), retryable: true)
            return
        }
        // Keep the lease alive for long-running work (lease is 5 minutes server-side).
        let keepAlive = Task { [api] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if Task.isCancelled { break }
                try? await api.extendLease(taskId: task.id, leaseToken: lease)
            }
        }
        defer { keepAlive.cancel() }
        // Execute first, then report. A reporting failure must never turn a success into a failure.
        let outcome: Result<JSONValue, Error>
        var retryable = true
        do {
            outcome = .success(try await exec.execute(task))
        } catch let e as ExecutorError {
            outcome = .failure(e)
            retryable = e.retryable
        } catch {
            outcome = .failure(error)
        }
        for attempt in 0..<3 {
            do {
                try await api.complete(taskId: task.id, leaseToken: lease, result: outcome, retryable: retryable)
                return
            } catch let e as APIError where e.status == 409 {
                return // lease lost: another device took over after expiry; the server keeps its result
            } catch {
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
            }
        }
        // Still unreported: the lease will expire and the server re-queues (retry-safe actions) or flags it.
    }
}
