import Foundation
import AppKit

enum NotchQCodexError: Error {
    case timeout, disconnected, unavailable, rejected(String, Double?)
    var description: String {
        switch self {
        case .timeout: return "Usage request timed out. Retrying automatically."
        case .disconnected: return "Codex connection closed. Reconnecting automatically."
        case .unavailable: return "Codex CLI unavailable. Open or reinstall Codex."
        case .rejected(let message, _): return message
        }
    }
    var retryAfter: Double? {
        if case .rejected(_, let delay) = self { return delay }
        return nil
    }
}

// Main-thread client: one JSON-line request at a time; credentials remain owned by Codex.
final class NotchQCodexClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = 0
    private var sequence = 0
    private var pending: (Int, (Result<[String: Any], NotchQCodexError>) -> Void)?
    private var deadline: Timer?
    private var ready = false
    private(set) var busy = false
    var onDisconnect: (() -> Void)?
    var executableOverride: URL?
    var timeout: TimeInterval = 8
    var processIdentifier: Int32? { process?.processIdentifier }

    static func notchQResolveExecutable() -> URL? {
        if let path = NotchQPreferences.codexCLI, FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        var candidates: [String] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates += [app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path, app.appendingPathComponent("Contents/Resources/codex").path]
        }
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        candidates += [
            userApps + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            userApps + "/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func notchQFetchUsage(_ completion: @escaping (Result<NotchQUsageSnapshot, NotchQCodexError>) -> Void) {
        guard !busy else { return }
        busy = true
        let read = { [weak self] in
            self?.notchQSendRequest("account/rateLimits/read", params: nil) { [weak self] result in
                self?.busy = false
                switch result {
                case .success(let object):
                    if let value = NotchQUsageSnapshot.notchQParseCodexLimits(object) { completion(.success(value)) }
                    else { completion(.failure(.rejected("Usage data unavailable for this account.", nil))) }
                case .failure(let error): completion(.failure(error))
                }
            }
        }
        if ready { read(); return }
        guard notchQStartClient() else { busy = false; completion(.failure(.unavailable)); return }
        busy = true
        notchQSendRequest("initialize", params: ["clientInfo": ["name": "codex_usage_menu_bar", "title": "NotchQ", "version": "1.0.0"]]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.notchQSendMessage(["method": "initialized", "params": [:]])
                self.ready = true; read()
            case .failure(let error): self.busy = false; completion(.failure(error))
            }
        }
    }

    private func notchQStartClient() -> Bool {
        guard let executable = executableOverride ?? Self.notchQResolveExecutable() else { return false }
        notchQStopClient()
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable
        task.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        generation += 1
        let current = generation
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                if data.isEmpty { self.notchQHandleDisconnect(); return }
                self.notchQReceiveMessage(data)
            }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                self.notchQHandleDisconnect()
            }
        }
        do { try task.run(); return true }
        catch { notchQStopClient(); return false }
    }

    private func notchQSendRequest(_ method: String, params: [String: Any]?, completion: @escaping (Result<[String: Any], NotchQCodexError>) -> Void) {
        sequence += 1
        let id = sequence
        pending = (id, completion)
        deadline = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self = self, self.pending?.0 == id else { return }
            let callback = self.pending?.1
            self.pending = nil; self.notchQStopClient()
            callback?(.failure(.timeout))
        }
        RunLoop.main.add(deadline!, forMode: .common)
        var object: [String: Any] = ["method": method, "id": id]
        if let params = params { object["params"] = params }
        notchQSendMessage(object)
    }

    private func notchQSendMessage(_ object: [String: Any]) {
        guard let input = input, var data = try? JSONSerialization.data(withJSONObject: object) else { notchQHandleDisconnect(); return }
        data.append(10)
        do { try input.write(contentsOf: data) } catch { notchQHandleDisconnect() }
    }

    private func notchQReceiveMessage(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 4_194_304 else { notchQHandleDisconnect(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = object["id"] as? Int, let waiting = pending, waiting.0 == id else { continue }
            pending = nil; deadline?.invalidate(); deadline = nil
            if let result = object["result"] as? [String: Any] { waiting.1(.success(result)) }
            else {
                let error = object["error"] as? [String: Any] ?? [:]
                let message = (error["message"] as? String ?? "").lowercased()
                let details = error["data"] as? [String: Any]
                let retry = (details?["retryAfterSeconds"] as? NSNumber)?.doubleValue
                // Display fixed messages, never raw server output or credential-bearing errors.
                let safe: String
                if message.contains("429") || message.contains("rate limit") || message.contains("too many") {
                    safe = "Usage service throttled. Waiting before retrying."
                } else if message.contains("auth") || message.contains("login") || message.contains("sign in") || message.contains("401") {
                    safe = "Sign in to Codex, then refresh."
                } else { safe = "Cannot fetch usage right now. Retrying automatically." }
                waiting.1(.failure(.rejected(safe, retry)))
            }
        }
    }

    private func notchQHandleDisconnect() {
        let callback = pending?.1
        pending = nil; notchQStopClient(); busy = false
        if let callback = callback { callback(.failure(.disconnected)) } else { onDisconnect?() }
    }

    func notchQStopClient(wait: Bool = false) {
        generation += 1; ready = false; pending = nil
        deadline?.invalidate(); deadline = nil
        output?.readabilityHandler = nil
        try? input?.close(); input = nil; output = nil; buffer.removeAll()
        if let task = process, task.isRunning {
            task.terminationHandler = nil
            task.terminate()
            let finish = {
                let until = Date().addingTimeInterval(2)
                while task.isRunning && Date() < until { usleep(20_000) }
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                task.waitUntilExit()
            }
            if wait { finish() } else { DispatchQueue.global().async(execute: finish) }
        }
        process = nil; busy = false
    }
}
