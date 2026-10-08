import Foundation
import CoreFoundation

enum NotchQClaudeConnectionError: LocalizedError {
    case invalidData, incompatibleStatusLine, conflictingConfiguration, missingBackup
    var errorDescription: String? {
        switch self {
        case .invalidData: return "Claude Code has not supplied a valid usage reading."
        case .incompatibleStatusLine: return "The current Claude Code status line is not a supported command configuration."
        case .conflictingConfiguration: return "Claude Code settings changed since connecting. Your current settings were preserved."
        case .missingBackup: return "The previous Claude Code status-line backup is unavailable."
        }
    }
}

struct NotchQClaudeReading {
    let snapshot: NotchQUsageSnapshot
    let observedAt: Date
    let fingerprint: String
}

// Uses Claude Code's documented status-line input. No tokens, cookies, or private endpoints.
final class NotchQClaudeConnection {
    let directory: URL
    let configuration: URL
    var cacheURL: URL { directory.appendingPathComponent("claude-usage.json") }
    var backupURL: URL { directory.appendingPathComponent("claude-statusline-backup.json") }

    init(directory: URL = NotchQPreferences.supportDirectory,
         configuration: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")) {
        self.directory = directory; self.configuration = configuration
    }
    private func notchQPrepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    }
    private func notchQWriteJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func notchQParseStatusLine(_ payload: [String: Any], now: Date = Date()) -> NotchQClaudeReading? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        var values: [[String: Any]] = []
        var windows: [NotchQUsageWindow] = []
        for (key, duration) in [("five_hour", 300), ("seven_day", 10080)] {
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percentage"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite,
                  let reset = window["resets_at"] as? NSNumber,
                  CFGetTypeID(reset) != CFBooleanGetTypeID(), reset.doubleValue.isFinite else { continue }
            let value = max(0, min(100, used.doubleValue))
            windows.append(NotchQUsageWindow(remaining: Int(floor(100 - value)), minutes: duration,
                                            reset: Date(timeIntervalSince1970: reset.doubleValue)))
            values.append(["key": key, "used": value, "reset": reset.doubleValue])
        }
        guard !windows.isEmpty else { return nil }
        let cost = payload["cost"] as? [String: Any] ?? [:]
        let context = payload["context_window"] as? [String: Any] ?? [:]
        // A repeating status-line timer does not make an old model-response snapshot fresh.
        // Only a new response counter or changed limit data advances the observation time.
        let fingerprintObject: [String: Any] = ["windows": values,
            "apiDuration": (cost["total_api_duration_ms"] as? NSNumber)?.doubleValue ?? 0,
            "inputTokens": (context["total_input_tokens"] as? NSNumber)?.doubleValue ?? 0,
            "outputTokens": (context["total_output_tokens"] as? NSNumber)?.doubleValue ?? 0]
        guard let bytes = try? JSONSerialization.data(withJSONObject: fingerprintObject, options: .sortedKeys) else { return nil }
        return NotchQClaudeReading(snapshot: NotchQUsageSnapshot(windows: windows), observedAt: now,
                                  fingerprint: bytes.base64EncodedString())
    }
    @discardableResult
    func notchQIngest(_ payload: [String: Any], now: Date = Date()) throws -> NotchQClaudeReading {
        guard let incoming = Self.notchQParseStatusLine(payload, now: now) else { try? FileManager.default.removeItem(at: cacheURL); throw NotchQClaudeConnectionError.invalidData }
        try notchQPrepareDirectory()
        let previous = notchQCachedReading(maximumAge: .infinity, now: now)
        let observed = previous?.fingerprint == incoming.fingerprint ? previous!.observedAt : now
        let windows = incoming.snapshot.windows.map { window -> [String: Any] in
            ["remaining": window.remaining, "minutes": window.minutes!, "reset": window.reset!.timeIntervalSince1970]
        }
        try notchQWriteJSON(["version": 1, "observedAt": observed.timeIntervalSince1970,
                            "fingerprint": incoming.fingerprint, "windows": windows], to: cacheURL)
        return NotchQClaudeReading(snapshot: incoming.snapshot, observedAt: observed, fingerprint: incoming.fingerprint)
    }
    func notchQCachedReading(maximumAge: TimeInterval = NotchQPreferences.claudeMaximumAge,
                            now: Date = Date()) -> NotchQClaudeReading? {
        guard let data = try? Data(contentsOf: cacheURL), data.count <= 65_536,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["version"] as? Int == 1, let time = object["observedAt"] as? Double,
              time.isFinite, time <= now.timeIntervalSince1970 + 5,
              now.timeIntervalSince1970 - time <= maximumAge,
              let fingerprint = object["fingerprint"] as? String,
              let values = object["windows"] as? [[String: Any]] else { return nil }
        let windows = values.compactMap { value -> NotchQUsageWindow? in
            guard let remaining = value["remaining"] as? Int, (0...100).contains(remaining),
                  let minutes = value["minutes"] as? Int, [300, 10080].contains(minutes),
                  let reset = value["reset"] as? Double, reset.isFinite else { return nil }
            return NotchQUsageWindow(remaining: remaining, minutes: minutes, reset: Date(timeIntervalSince1970: reset))
        }
        guard !windows.isEmpty else { return nil }
        return NotchQClaudeReading(snapshot: NotchQUsageSnapshot(windows: windows), observedAt: Date(timeIntervalSince1970: time), fingerprint: fingerprint)
    }
    private func notchQConfiguration() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configuration.path) else { return [:] }
        let data = try Data(contentsOf: configuration)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotchQClaudeConnectionError.invalidData }
        return object
    }
    private func notchQBackup() -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: backupURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
    var isConnected: Bool {
        guard let saved = notchQBackup(), let command = saved["installedCommand"] as? String,
              let config = try? notchQConfiguration(),
              let status = config["statusLine"] as? [String: Any] else { return false }
        return status["command"] as? String == command
    }
    func notchQConnect(executable: URL) throws {
        try notchQPrepareDirectory()
        if isConnected { return }
        var config = try notchQConfiguration()
        let original = config["statusLine"]
        if let original = original, !(original is NSNull) {
            guard let settings = original as? [String: Any], settings["type"] as? String == "command",
                  settings["command"] is String else { throw NotchQClaudeConnectionError.incompatibleStatusLine }
        }
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = quoted + " --claude-statusline"
        try notchQWriteJSON(["version": 1, "original": original ?? NSNull(), "installedCommand": command], to: backupURL)
        var status = original as? [String: Any] ?? [:]
        status["type"] = "command"; status["command"] = command
        config["statusLine"] = status
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try notchQWriteJSON(config, to: configuration)
    }
    func notchQDisconnect() throws {
        guard let backup = notchQBackup() else { throw NotchQClaudeConnectionError.missingBackup }
        var config = try notchQConfiguration()
        guard let status = config["statusLine"] as? [String: Any],
              status["command"] as? String == backup["installedCommand"] as? String else { throw NotchQClaudeConnectionError.conflictingConfiguration }
        if let original = backup["original"], !(original is NSNull) { config["statusLine"] = original }
        else { config.removeValue(forKey: "statusLine") }
        try notchQWriteJSON(config, to: configuration)
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }
    func notchQOriginalStatusCommand() -> String? {
        (notchQBackup()?["original"] as? [String: Any])?["command"] as? String
    }
    static func notchQStatusLineMain() -> Int32 {
        var input = Data()
        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            input.append(chunk)
            if input.count > 1_048_576 { return 1 }
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return 1 }
        let connection = NotchQClaudeConnection()
        let reading = try? connection.notchQIngest(payload)
        if let command = connection.notchQOriginalStatusCommand() {
            // Preserve the user's already configured status-line command and its stdin.
            let process = Process(), stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
            process.standardInput = stdin; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                DispatchQueue.global().async { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
                let until = Date().addingTimeInterval(3)
                while process.isRunning && Date() < until { usleep(10_000) }
                if process.isRunning { process.terminate(); usleep(50_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                process.waitUntilExit()
            } catch { return 1 }
        } else if let reading = reading {
            print("Claude: \(reading.snapshot.remaining)% remaining")
        }
        return 0
    }
}
