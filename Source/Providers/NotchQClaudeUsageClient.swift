import Foundation
import Darwin

struct NotchQClaudeUsageParser {
    static func notchQPlainText(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)|\u{001B}\\[[0-?]*[ -/]*[@-~]|\u{001B}.", with: "", options: .regularExpression)
    }
    /// Claude Code prints resets as text in a named zone, e.g. "11pm (Europe/Stockholm)" or
    /// "Oct 15 at 5pm (Europe/Stockholm)". Converting them to dates lets the menu show every
    /// provider's resets in the viewer's own time zone and format, without a zone label.
    static func notchQResetDate(_ text: String, now: Date = Date()) -> Date? {
        let pattern = try! NSRegularExpression(pattern: "^(?:([A-Za-z]{3}) (\\d{1,2})(?:,| at)? )?(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\s*\\(([^()\\s]+)\\)$", options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard let zone = group(6).flatMap(TimeZone.init(identifier:)), let hour12 = group(3).flatMap(Int.init), (1...12).contains(hour12) else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour12 % 12 + (group(5)!.lowercased() == "pm" ? 12 : 0); parts.minute = minute
        if let month = group(1), let day = group(2).flatMap(Int.init) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let index = months.firstIndex(of: month.lowercased()), (1...31).contains(day) else { return nil }
            parts.month = index + 1; parts.day = day
            guard var date = calendar.date(from: parts) else { return nil }
            // A date well in the past belongs to next year (e.g. a "Jan 2" reset seen on Dec 30).
            if date < now.addingTimeInterval(-180 * 86_400) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
            return date
        }
        // Time only: the next occurrence, which is how the five-hour reset is reported.
        guard let today = calendar.date(from: parts) else { return nil }
        return today < now.addingTimeInterval(-60) ? calendar.date(byAdding: .day, value: 1, to: today) : today
    }
    static func notchQParse(_ value: String, now: Date = Date()) -> NotchQUsageSnapshot? {
        let text = notchQPlainText(value).replacingOccurrences(of: "\r", with: "")
        // /usage ends with this screen-reader footer, even for a one-window account.
        let footer = try! NSRegularExpression(pattern: "(?im)^Esc to cancel[^\n]*")
        let endings = footer.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = endings.last, let end = Range(last.range, in: text) else { return nil }
        let start = endings.dropLast().last.flatMap { Range($0.range, in: text)?.upperBound } ?? text.startIndex
        let trailing = String(text[end.upperBound...])
        if trailing.contains("Current session") || trailing.contains("Current week") || trailing.contains("Loading usage") { return nil }
        let frame = String(text[start..<end.lowerBound])
        let headers = try! NSRegularExpression(pattern: "(?m)^Current (session|week \\([^\n]*\\))[ \t]*$")
        let matches = headers.matches(in: frame, range: NSRange(frame.startIndex..., in: frame))
        var windows: [NotchQUsageWindow] = []
        for (index, match) in matches.enumerated() {
            guard let label = Range(match.range(at: 1), in: frame), let heading = Range(match.range, in: frame) else { return nil }
            guard frame[label] == "session" || frame[label] == "week (all models)" else { continue }
            let minutes = frame[label] == "session" ? 300 : 10080
            // A repeated header is a new redraw; never combine it with an older window.
            if minutes == 300 || windows.contains(where: { $0.minutes == minutes }) { windows.removeAll() }
            let stop = index + 1 < matches.count ? Range(matches[index + 1].range, in: frame)!.lowerBound : frame.endIndex
            let block = String(frame[heading.upperBound..<stop])
            let usedRegex = try! NSRegularExpression(pattern: "(?:[0-9]+(?:\\.[0-9]+)?%[ \t]+)?([0-9]+(?:\\.[0-9]+)?)% used")
            guard let usedMatch = usedRegex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
                  let usedRange = Range(usedMatch.range(at: 1), in: block), let used = Double(block[usedRange]),
                  used.isFinite, (0...100).contains(used) else { return nil }
            let resetRegex = try! NSRegularExpression(pattern: "(?m)^Resets ([^\n]+)")
            let reset = resetRegex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block))
                .flatMap { Range($0.range(at: 1), in: block) }.map { String(block[$0].prefix(160)).trimmingCharacters(in: .whitespaces) }
            windows.append(NotchQUsageWindow(remaining: Int(floor(100 - used)), minutes: minutes, reset: reset.flatMap { notchQResetDate($0, now: now) }, resetDescription: reset))
        }
        return windows.isEmpty ? nil : NotchQUsageSnapshot(windows: windows)
    }
}

// Uses the vendor's documented, read-only /usage UI. Authentication remains with Claude Code.
// A private PTY is required; no model prompts, token extraction or direct private API calls.
final class NotchQClaudeUsageClient {
    private var process: Process?
    private var terminal: FileHandle?
    private var buffer = ""
    private var pending: ((Result<NotchQUsageSnapshot, NotchQSourceError>) -> Void)?
    private var deadline: Timer?
    private var settle: Timer?
    private var generation = 0
    private var requestedTrust = false
    private var finishing = false
    private let cleanup = DispatchGroup()
    private var shutdownCompletion: (() -> Void)?
    var onIdle: (() -> Void)?
    var processIdentifier: Int32? { process?.processIdentifier }
    private var unexpectedModelActivity = false
    private(set) var busy = false
    var executableOverride: URL?
    var locator = NotchQExecutableLocator.shared
    var timeout: TimeInterval = 8
    private let directory: URL

    init(directory: URL = NotchQPreferences.supportDirectory.appendingPathComponent("UsageCheck", isDirectory: true)) {
        self.directory = directory
    }
    func notchQFetchUsage(_ callback: @escaping (Result<NotchQUsageSnapshot, NotchQSourceError>) -> Void) {
        guard !busy else { return }
        guard !unexpectedModelActivity else {
            callback(.failure(.rejected("Claude usage checker stopped after unexpected model activity. Restart NotchQ to retry.", nil))); return
        }
        busy = true; pending = callback; buffer = ""
        if !notchQStart() {
            notchQComplete(.failure(.rejected("Claude Code is unavailable. Install it or open Claude Code in Claude Desktop, then sign in with Pro/Max.", nil))); return
        }
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            self?.notchQComplete(.failure(.rejected("Claude usage check timed out. Sign in to Claude Code; terminal output may be incompatible. Retrying automatically.", nil)))
        }
        deadline = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func notchQStart() -> Bool {
        guard let executable = executableOverride ?? locator.notchQLocate(.claude)?.url else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { return false }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { return false }
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 60, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return false }
        let task = Process(), reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        task.executableURL = executable; task.currentDirectoryURL = directory
        task.arguments = ["--restricted", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true,\"hooks\":{}}", "--ax-screen-reader", "/usage"]
        var environment = locator.notchQChildEnvironment(for: executable)
        environment["TERM"] = "xterm-256color"; environment["LANG"] = "en_US.UTF-8"
        // Each check is a short-lived process; skip its updater and reporting traffic.
        for key in ["DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING"] { environment[key] = "1" }
        task.environment = environment; task.standardInput = child; task.standardOutput = child; task.standardError = child
        generation += 1; let current = generation; requestedTrust = false
        reader.readabilityHandler = { [weak self] handle in
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            let data = count > 0 ? Data(bytes.prefix(count)) : Data()
            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                if data.isEmpty { self.notchQComplete(.failure(.exited)); return }
                self.notchQReceive(data)
            }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                self.notchQComplete(.failure(.exited))
            }
        }
        process = task; terminal = reader
        do { try task.run(); try? child.close(); return true }
        catch {
            generation += 1; reader.readabilityHandler = nil; try? reader.close(); terminal = nil; process = nil
            return false
        }
    }
    private func notchQWrite(_ value: String) {
        do { try terminal?.write(contentsOf: Data(value.utf8)) }
        catch { notchQComplete(.failure(.exited)) }
    }
    private func notchQReceive(_ data: Data) {
        guard busy else { return }
        buffer += String(decoding: data, as: UTF8.self)
        guard buffer.utf8.count <= 131_072 else { notchQComplete(.failure(.exited)); return }
        let plain = NotchQClaudeUsageParser.notchQPlainText(buffer)
        if let regex = try? NSRegularExpression(pattern: "Total cost:\\s+\\$([0-9.]+)"),
           let match = regex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
           let range = Range(match.range(at: 1), in: plain), let cost = Double(plain[range]), cost > 0 {
            unexpectedModelActivity = true
            notchQComplete(.failure(.rejected("Claude usage checker detected unexpected model activity and stopped.", nil))); return
        }
        if !requestedTrust && plain.contains("Quick safety check:") && plain.contains(directory.path) {
            // Only our private, empty usage-check folder is trusted; model tools remain disabled.
            guard (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true else {
                notchQComplete(.failure(.rejected("Claude usage-check folder is not empty. Setup requires attention.", nil))); return
            }
            requestedTrust = true; buffer = ""; notchQWrite(plain.contains("Enter y/n:") ? "y\r" : "\u{001B}[B\r"); return
        }
        let throttled = plain.range(of: "(?i)(?:\\b(?:API\\s*)?error[:\\s]+429\\b|\\bHTTP\\b[^\\r\\n]{0,16}\\b429\\b|\\b429[ :]+too many requests\\b|\\btoo many requests\\b|\\brate[ _-]?limit(?:ed|_error)\\b)", options: .regularExpression) != nil
        if throttled {
            notchQComplete(.failure(.rejected("Usage service throttled. Waiting before retrying.", 60))); return
        }
        if plain.contains("Not logged in") || plain.contains("Please run /login") {
            notchQComplete(.failure(.rejected("Sign in to Claude Code with your Pro/Max account, then refresh.", nil))); return
        }
        // Terminal output can split immediately before the final reset line.
        // Wait briefly for that line rather than completing on the percentages alone.
        settle?.invalidate(); settle = nil
        if NotchQClaudeUsageParser.notchQParse(plain) != nil {
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                guard let self = self, self.busy,
                      let snapshot = NotchQClaudeUsageParser.notchQParse(self.buffer) else { return }
                self.notchQComplete(.success(snapshot))
            }
            settle = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func notchQComplete(_ result: Result<NotchQUsageSnapshot, NotchQSourceError>) {
        guard !finishing else { return }
        let callback = pending; pending = nil
        notchQShutdown(wait: false) { [weak self] in
            guard let self = self else { return }
            callback?(result)
            self.onIdle?()
        }
    }
    func notchQStop(wait: Bool = false) { pending = nil; notchQShutdown(wait: wait) { [weak self] in self?.onIdle?() } }
    private func notchQShutdown(wait: Bool, completion: @escaping () -> Void) {
        shutdownCompletion = completion
        if finishing {
            if wait { cleanup.wait(); notchQShutdownDone(generation) }
            return
        }
        generation += 1; let current = generation
        finishing = true; busy = true
        deadline?.invalidate(); deadline = nil; settle?.invalidate(); settle = nil; buffer = ""
        terminal?.readabilityHandler = nil; try? terminal?.close(); terminal = nil
        let task = process; process = nil
        if let task = task, task.isRunning { task.terminationHandler = nil; task.terminate() }
        cleanup.enter()
        let finish = { [cleanup] in
            if let task = task {
                let until = Date().addingTimeInterval(2)
                while task.isRunning && Date() < until { usleep(20_000) }
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                task.waitUntilExit()
            }
            cleanup.leave()
        }
        if wait { finish(); notchQShutdownDone(current) }
        else { DispatchQueue.global().async { [weak self] in
            finish(); DispatchQueue.main.async { self?.notchQShutdownDone(current) }
        } }
    }
    private func notchQShutdownDone(_ current: Int) {
        guard generation == current, finishing else { return }
        finishing = false; busy = false
        NotchQDiagnostics.shared.record(.stopped, provider: .claude)
        let callback = shutdownCompletion; shutdownCompletion = nil; callback?()
    }
}
