import AppKit
import Darwin

struct NotchQExecutableLocation: Equatable {
    enum Source { case chosen, automatic }
    let url: URL
    let source: Source
}

// Finds vendor CLIs the way the user's Terminal would, even when NotchQ is opened from Finder
// or at login with launchd's minimal PATH. Results are cached briefly; never resolved per poll.
final class NotchQExecutableLocator {
    static let shared = NotchQExecutableLocator()
    static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    let home: URL
    let systemDirectories: [String]
    let applicationDirectories: [String]
    private let applicationURL: (String) -> URL?
    private let chosenPath: (NotchQProvider) -> String?
    /// The user's login-shell PATH, captured once in the background. Never logged.
    var loginPath: [String] = [] { didSet { notchQInvalidate() } }
    var cacheLifetime: TimeInterval = 60
    private var cache: [NotchQProvider: (location: NotchQExecutableLocation?, at: Date)] = [:]
    private var reported: [NotchQProvider: NotchQDiagnostics.Reason] = [:]
    private var capturing = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         systemDirectories: [String] = NotchQExecutableLocator.systemDirectories,
         applicationDirectories: [String]? = nil,
         applicationURL: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
         chosenPath: @escaping (NotchQProvider) -> String? = { NotchQPreferences.chosenCLI($0) }) {
        self.home = home; self.systemDirectories = systemDirectories
        self.applicationDirectories = applicationDirectories ?? [home.appendingPathComponent("Applications").path, "/Applications"]
        self.applicationURL = applicationURL; self.chosenPath = chosenPath
    }

    func notchQInvalidate() { cache.removeAll() }

    func notchQLocate(_ provider: NotchQProvider, now: Date = Date()) -> NotchQExecutableLocation? {
        if let cached = cache[provider], now.timeIntervalSince(cached.at) < cacheLifetime { return cached.location }
        let location = notchQResolve(provider)
        cache[provider] = (location, now)
        // Log only changes in how a CLI was found; never its path.
        let how: NotchQDiagnostics.Reason = location.map { $0.source == .chosen ? .chosen : .automatic } ?? .notFound
        if reported[provider] != how, self === NotchQExecutableLocator.shared {
            reported[provider] = how; NotchQDiagnostics.shared.record(.detected, provider: provider, reason: how)
        }
        return location
    }

    private func notchQResolve(_ provider: NotchQProvider) -> NotchQExecutableLocation? {
        let files = FileManager.default
        if let path = chosenPath(provider), files.isExecutableFile(atPath: path) {
            return NotchQExecutableLocation(url: URL(fileURLWithPath: path), source: .chosen)
        }
        let found = notchQCandidates(provider).first { files.isExecutableFile(atPath: $0) }
            ?? (provider == .claude ? notchQDesktopClaude() : nil)
        return found.map { NotchQExecutableLocation(url: URL(fileURLWithPath: $0), source: .automatic) }
    }

    func notchQCandidates(_ provider: NotchQProvider) -> [String] {
        let name = provider == .codex ? "codex" : "claude"
        var candidates: [String] = []
        if provider == .codex {
            if let app = applicationURL(provider.bundleIdentifier) {
                candidates += [app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path,
                               app.appendingPathComponent("Contents/Resources/codex").path]
            }
            for root in applicationDirectories {
                candidates += [root + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                               root + "/Codex.app/Contents/Resources/codex"]
            }
        }
        var directories = [home.appendingPathComponent(".local/bin").path]
        if provider == .claude { directories.append(home.appendingPathComponent(".claude/local").path) }
        directories += systemDirectories
        directories += [".npm-global/bin", ".volta/bin", ".bun/bin", ".yarn/bin"].map { home.appendingPathComponent($0).path }
        directories += notchQNodeVersionDirectories()
        directories += loginPath
        candidates += directories.map { $0 + "/" + name }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    // nvm installs one bin folder per Node version; prefer the newest.
    private func notchQNodeVersionDirectories() -> [String] {
        let root = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { root.appendingPathComponent($0).appendingPathComponent("bin").path }
    }

    // Claude Desktop keeps its own Claude Code copy in a versioned cache folder.
    private func notchQDesktopClaude() -> String? {
        let cache = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        guard let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil) else { return nil }
        let matches = files.compactMap { $0 as? URL }.map(\.path)
            .filter { $0.hasSuffix("/claude.app/Contents/MacOS/claude") && FileManager.default.isExecutableFile(atPath: $0) }
        return matches.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first
    }

    // npm, nvm and Volta CLIs are `#!/usr/bin/env node` scripts; node must be on the child's PATH.
    func notchQChildEnvironment(for executable: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let inherited = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let path = ([executable.deletingLastPathComponent().path] + loginPath + Self.systemDirectories + inherited + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    static let loginPathBegin = "__NOTCHQ_PATH_BEGIN__", loginPathEnd = "__NOTCHQ_PATH_END__"
    static func notchQParseLoginPath(_ output: String) -> [String]? {
        guard let start = output.range(of: loginPathBegin), let end = output.range(of: loginPathEnd, range: start.upperBound..<output.endIndex) else { return nil }
        let value = output[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = value.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return entries.isEmpty ? nil : entries
    }

    /// Reads PATH from the user's interactive login shell, where nvm/Volta/Homebrew are usually configured.
    static func notchQReadLoginPath(timeout: TimeInterval = 5) -> [String]? {
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-ilc", "echo \(loginPathBegin); /usr/bin/printenv PATH; echo \(loginPathEnd)"]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = output; task.standardError = FileHandle.nullDevice
        var data = Data()
        let reader = DispatchGroup(); reader.enter()
        DispatchQueue.global().async { data = output.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        do { try task.run() } catch { return nil }
        if reader.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate(); usleep(100_000)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            return nil
        }
        task.waitUntilExit()
        return notchQParseLoginPath(String(decoding: data, as: UTF8.self))
    }

    func notchQCaptureLoginPath(_ completion: @escaping () -> Void) {
        guard !capturing else { return }
        capturing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = Self.notchQReadLoginPath()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.capturing = false
                NotchQDiagnostics.shared.record(.detected, detail: path.map { "loginPATH=captured(\($0.count))" } ?? "loginPATH=unavailable")
                if let path = path, path != self.loginPath { self.loginPath = path; completion() }
            }
        }
    }
}
