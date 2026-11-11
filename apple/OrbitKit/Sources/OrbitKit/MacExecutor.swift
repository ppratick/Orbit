#if os(macOS)
import AppKit
import Foundation
import PDFKit

/// Mac companion capabilities: local files, scripts, Shortcuts and handing pages to the browser.
///
/// Safety model (defence in depth — the server already gated approvals):
///  - Allow-listed scripts live in ~/Orbit/Scripts and are referenced by file name only.
///  - Arbitrary commands and overwrites run only when the task carries an approval id.
///  - New files default to ~/Orbit/Files and never overwrite unless approved.
public final class MacExecutor: DeviceExecutor, @unchecked Sendable {
    public let actions = ["mac.search_files", "mac.read_file", "mac.write_file", "mac.run_script", "mac.open_url", "shortcuts.run"]
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let orbitDir = home.appendingPathComponent("Orbit", isDirectory: true)
    public static let scriptsDir = orbitDir.appendingPathComponent("Scripts", isDirectory: true)
    public static let filesDir = orbitDir.appendingPathComponent("Files", isDirectory: true)
    private let maxOutput = 60_000

    public init() {
        for d in [Self.scriptsDir, Self.filesDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// Script names the user has placed in ~/Orbit/Scripts (advertised as capabilities "script:<name>").
    public static func allowListedScripts() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: scriptsDir.path)) ?? []
        return items.filter { !$0.hasPrefix(".") && FileManager.default.isExecutableFile(atPath: scriptsDir.appendingPathComponent($0).path) }.sorted()
    }

    public func execute(_ task: OrbitTask) async throws -> JSONValue {
        let p = task.params
        switch task.action {
        case "mac.search_files": return try await searchFiles(p)
        case "mac.read_file": return try readFile(p)
        case "mac.write_file": return try writeFile(task, p)
        case "mac.run_script": return try await runScript(task, p)
        case "mac.open_url": return try await openURL(p)
        case "shortcuts.run": return try await runShortcut(task, p)
        default: throw ExecutorError("Unsupported action \(task.action)")
        }
    }

    func resolve(_ raw: String, defaultDir: URL? = nil) -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~") { path = Self.home.path + path.dropFirst() }
        if !path.hasPrefix("/") { return (defaultDir ?? Self.home).appendingPathComponent(path).standardizedFileURL }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func searchFiles(_ p: JSONValue) async throws -> JSONValue {
        guard let q = p["query"]?.string, !q.isEmpty else { throw ExecutorError("query required") }
        var args = [q]
        if let folder = p["folder"]?.string, !folder.isEmpty { args = ["-onlyin", resolve(folder).path, q] }
        let r = try await Process.run("/usr/bin/mdfind", args, timeout: 30)
        let paths = r.stdout.split(separator: "\n").prefix(40).map { JSONValue.string(String($0)) }
        return .object(["matches": .array(paths), "total": .number(Double(r.stdout.split(separator: "\n").count))])
    }

    private func readFile(_ p: JSONValue) throws -> JSONValue {
        guard let raw = p["path"]?.string else { throw ExecutorError("path required") }
        let url = resolve(raw)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExecutorError("File not found: \(url.path)") }
        let ext = url.pathExtension.lowercased()
        var text: String
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ExecutorError("Could not open PDF") }
            text = doc.string ?? ""
        } else if ["docx", "doc", "rtf", "rtfd", "odt", "html", "webarchive", "pages"].contains(ext) {
            let attr = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            text = attr.string
        } else {
            guard let data = FileManager.default.contents(atPath: url.path) else { throw ExecutorError("Unreadable file") }
            guard let s = String(data: data.prefix(2_000_000), encoding: .utf8) else { throw ExecutorError("Binary file; no text to extract") }
            text = s
        }
        let truncated = text.count > maxOutput
        return .object(["path": .string(url.path), "text": .string(String(text.prefix(maxOutput))), "truncated": .bool(truncated)])
    }

    private func writeFile(_ task: OrbitTask, _ p: JSONValue) throws -> JSONValue {
        guard let raw = p["path"]?.string, let content = p["content"]?.string else { throw ExecutorError("path and content required") }
        let url = resolve(raw, defaultDir: Self.filesDir)
        let overwrite = p["overwrite"]?.bool ?? false
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            // Retried task that already wrote this exact content → success, not a duplicate.
            if let cur = try? String(contentsOf: url, encoding: .utf8), cur == content { return .object(["path": .string(url.path), "unchanged": .bool(true)]) }
            guard overwrite, task.approvalId != nil else { throw ExecutorError("\(url.path) already exists; overwriting needs approval") }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return .object(["path": .string(url.path), "bytes": .number(Double(content.utf8.count)), "overwrote": .bool(exists)])
    }

    private func runScript(_ task: OrbitTask, _ p: JSONValue) async throws -> JSONValue {
        let args = p["args"]?.array?.compactMap { $0.string } ?? []
        let r: Process.Output
        if let name = p["script"]?.string, !name.isEmpty, p["command"] == nil {
            guard !name.contains("/"), !name.hasPrefix("."), Self.allowListedScripts().contains(name) else {
                throw ExecutorError("\"\(name)\" is not an executable script in ~/Orbit/Scripts")
            }
            r = try await Process.run(Self.scriptsDir.appendingPathComponent(name).path, args, cwd: Self.orbitDir, timeout: 300)
        } else if let cmd = p["command"]?.string, !cmd.isEmpty {
            guard task.approvalId != nil else { throw ExecutorError("Arbitrary commands require approval") }
            r = try await Process.run("/bin/zsh", ["-lc", cmd], cwd: Self.home, timeout: 300)
        } else {
            throw ExecutorError("script or command required")
        }
        return .object([
            "exit_code": .number(Double(r.status)),
            "stdout": .string(String(r.stdout.suffix(maxOutput))),
            "stderr": .string(String(r.stderr.suffix(8_000))),
        ])
    }

    @MainActor private func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    private func openURL(_ p: JSONValue) async throws -> JSONValue {
        guard let s = p["url"]?.string, let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ExecutorError("A valid http(s) URL is required") }
        let ok = await open(url)
        return .object(["opened": .bool(ok)])
    }

    private func runShortcut(_ task: OrbitTask, _ p: JSONValue) async throws -> JSONValue {
        guard task.approvalId != nil else { throw ExecutorError("Running Shortcuts requires approval") }
        guard let name = p["name"]?.string else { throw ExecutorError("name required") }
        var args = ["run", name]
        var input: URL?
        if let text = p["input"]?.string, !text.isEmpty {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-shortcut-\(task.id).txt")
            try text.write(to: f, atomically: true, encoding: .utf8)
            args += ["--input-path", f.path]
            input = f
        }
        defer { if let input { try? FileManager.default.removeItem(at: input) } }
        let r = try await Process.run("/usr/bin/shortcuts", args, timeout: 300)
        return .object(["exit_code": .number(Double(r.status)), "output": .string(String(r.stdout.suffix(maxOutput)))])
    }
}

extension Process {
    public struct Output: Sendable { public var status: Int32; public var stdout: String; public var stderr: String }

    /// Run a process without a shell (unless the caller asks for zsh), with a timeout and captured output.
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            final class Box: @unchecked Sendable { var outData = Data(); var errData = Data(); let lock = NSLock() }
            let box = Box()
            out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; box.lock.lock(); if box.outData.count < 4_000_000 { box.outData.append(d) }; box.lock.unlock() }
            err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; box.lock.lock(); if box.errData.count < 1_000_000 { box.errData.append(d) }; box.lock.unlock() }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                box.lock.lock()
                box.outData.append(out.fileHandleForReading.readDataToEndOfFile())
                box.errData.append(err.fileHandleForReading.readDataToEndOfFile())
                let o = Output(status: proc.terminationStatus, stdout: String(decoding: box.outData, as: UTF8.self), stderr: String(decoding: box.errData, as: UTF8.self))
                box.lock.unlock()
                cont.resume(returning: o)
            }
            do { try p.run() } catch { cont.resume(throwing: ExecutorError("Could not start \(executable): \(error.localizedDescription)")); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}
#endif
