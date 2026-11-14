import AppKit

/// Starts Claude Code's own sign-in for the user and watches for it to finish.
///
/// The sign-in runs in Terminal, from a small script that holds only the CLI's path and `auth login`:
/// Claude Code opens the browser itself and, when the browser cannot report back, asks for a code to be
/// pasted, which needs a real terminal. NotchQ never sees the account or its credentials; it only asks
/// `claude auth status` whether someone is signed in and reads that one field.
final class NotchQClaudeSignIn {
    enum Outcome { case signedIn, timedOut, failedToStart }
    static let scriptName = "Sign in to Claude Code.command"
    static let waitingMessage = "Waiting for sign-in to finish in your browser…"
    static let slashLoginMessage = "Claude Code opened in Terminal. Type /login there, then finish signing in in your browser."

    var locator = NotchQExecutableLocator.shared
    var directory: URL
    /// How often `claude auth status` is asked, and for how long.
    var interval: TimeInterval = 5
    var limit: TimeInterval = 300
    /// Replaced in tests, which must never start a real sign-in.
    var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    lazy var supportsAuthLogin: (URL, @escaping (Bool) -> Void) -> Void = { [unowned self] executable, completion in
        self.notchQRun(executable, ["auth", "login", "--help"]) { completion(Self.notchQHelpNamesAuthLogin($0)) }
    }
    lazy var probe: (URL, @escaping (Bool?) -> Void) -> Void = { [unowned self] executable, completion in
        self.notchQRun(executable, ["auth", "status", "--json"]) { completion(Self.notchQParseLoggedIn($0)) }
    }
    private(set) var waiting = false
    /// Older Claude Code without `auth login`: plain `claude` was opened and the user types /login.
    private(set) var usesSlashLogin = false
    var message: String { usesSlashLogin ? Self.slashLoginMessage : Self.waitingMessage }
    private var generation = 0
    private var timer: Timer?
    private var probing = false

    init(directory: URL = NotchQPreferences.supportDirectory) { self.directory = directory }

    /// POSIX single-quoting: nothing is special inside single quotes; a quote itself becomes '\''.
    static func notchQShellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// The whole script: the quoted absolute CLI path and NotchQ's own fixed arguments (`auth login` or none), nothing else.
    static func notchQScript(executable: URL, arguments: [String]) -> String {
        // The path is the located absolute one, so the sign-in never depends on the user's PATH.
        "#!/bin/sh\nexec " + ([notchQShellQuoted(executable.path)] + arguments).joined(separator: " ") + "\n"
    }
    /// Only the `loggedIn` field is read; the rest of the status output is discarded unseen.
    static func notchQParseLoggedIn(_ data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["loggedIn"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    static func notchQHelpNamesAuthLogin(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).contains("claude auth login")
    }

    /// Writes the script (owner-only, replaced each time) and returns its location.
    func notchQWriteScript(executable: URL, arguments: [String]) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(Self.scriptName)
        // Remove whatever is there (a link included) so the write cannot follow it elsewhere.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil { try manager.removeItem(at: url) }
        guard manager.createFile(atPath: url.path, contents: Data(Self.notchQScript(executable: executable, arguments: arguments).utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Opens the sign-in in Terminal and reports once: signed in, timed out, or could not start.
    /// Only one sign-in is ever in progress; a second call while waiting does nothing.
    @discardableResult
    func notchQStart(executable: URL, changed: @escaping () -> Void, completion: @escaping (Outcome) -> Void) -> Bool {
        guard !waiting else { return false }
        waiting = true; usesSlashLogin = false; generation += 1
        let current = generation, started = Date()
        supportsAuthLogin(executable) { [weak self] supported in
            guard let self = self, self.waiting, self.generation == current else { return }
            self.usesSlashLogin = !supported
            guard let script = try? self.notchQWriteScript(executable: executable, arguments: supported ? ["auth", "login"] : []), self.open(script) else {
                self.notchQStop(); completion(.failedToStart); return
            }
            changed()
            let timer = Timer(timeInterval: self.interval, repeats: true) { [weak self] _ in
                guard let self = self, self.waiting, self.generation == current else { return }
                if Date().timeIntervalSince(started) >= self.limit { self.notchQStop(); completion(.timedOut); return }
                guard !self.probing else { return }
                self.probing = true
                self.probe(executable) { [weak self] loggedIn in
                    guard let self = self else { return }
                    self.probing = false
                    guard self.waiting, self.generation == current, loggedIn == true else { return }
                    self.notchQStop(); completion(.signedIn)
                }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }
    /// Stops waiting (quit, sleep, Claude switched off, or done). The Terminal window is the user's to close.
    func notchQStop() {
        waiting = false; generation += 1; probing = false
        timer?.invalidate(); timer = nil
    }

    /// Runs one short, read-only CLI query and hands back its standard output. Nothing is logged.
    private func notchQRun(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 10, completion: @escaping (Data) -> Void) {
        let environment = locator.notchQChildEnvironment(for: executable)
        DispatchQueue.global(qos: .utility).async {
            let task = Process(), output = Pipe()
            task.executableURL = executable; task.arguments = arguments; task.environment = environment
            task.standardInput = FileHandle.nullDevice; task.standardOutput = output; task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { DispatchQueue.main.async { completion(Data()) }; return }
            let stop = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit(); stop.cancel()
            DispatchQueue.main.async { completion(data.count <= 65_536 ? data : Data()) }
        }
    }
}
