import AppKit
import Darwin

/// "Report a Bug…": copies NotchQ's own log to the clipboard and opens GitHub's bug form with the
/// version, macOS version and processor prefilled. The log is too long for a URL, so it is pasted.
enum NotchQBugReport {
    static let form = "https://github.com/Xentiles/NotchQ/issues/new"
    // Must match the text-field ids in .github/ISSUE_TEMPLATE/bug_report.yml. GitHub only prefills
    // text fields (input/textarea) from a link, not dropdowns, so every prefilled field is text.
    static let appleSilicon = "Apple silicon (M-series)", intel = "Intel"
    /// Keeps the whole link under GitHub's URL limit (longer links fail with "414 URI Too Long").
    static let linkBudget = 7000

    struct Environment {
        var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var macOS: String = {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }()
        /// True on Apple silicon even when running translated under Rosetta.
        var isAppleSilicon: Bool = {
            var value: Int32 = 0; var size = MemoryLayout<Int32>.size
            return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        }()
        var summary: String { "NotchQ Bv\(version) (build \(build)) · \(macOS) · \(isAppleSilicon ? appleSilicon : intel)" }
    }

    static func notchQFormURL(_ environment: Environment = Environment(), log: String? = nil) -> URL {
        var components = URLComponents(string: form)!
        var items = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: "Bv\(environment.version) (build \(environment.build))"),
            URLQueryItem(name: "macos", value: environment.macOS),
            URLQueryItem(name: "chip", value: environment.isAppleSilicon ? appleSilicon : intel)]
        components.queryItems = items
        if let log = log {
            let room = linkBudget - components.url!.absoluteString.count - "&log=".count
            items.append(URLQueryItem(name: "log", value: notchQExcerpt(log, encodedBudget: room)))
            components.queryItems = items
        }
        return components.url!
    }

    /// `log show` lines shortened to "HH:MM:SS [E] event=…", newest kept first when the budget runs out.
    static func notchQCompact(_ line: String) -> String {
        guard let event = line.range(of: "event=") else { return line }
        let time = line.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression).map { String(line[$0]) } ?? ""
        let error = line.range(of: #"\.\d+ E "#, options: .regularExpression) != nil ? "E " : ""
        return "\(time) \(error)\(line[event.lowerBound...])"
    }
    static func notchQExcerpt(_ log: String, encodedBudget: Int) -> String {
        func encoded(_ text: String) -> Int { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)?.count ?? text.count * 3 }
        var lines = log.split(separator: "\n").map(String.init)
        let summary = lines.isEmpty ? "" : lines.removeFirst()
        let events = lines.map(notchQCompact)
        var kept: [String] = []
        for line in events.reversed() {
            let note = "(latest \(kept.count + 1) of \(events.count) entries; the full log is on your clipboard)"
            if encoded(([summary, note] + [line] + kept).joined(separator: "\n")) > encodedBudget { break }
            kept.insert(line, at: 0)
        }
        let note = kept.count < events.count ? ["(latest \(kept.count) of \(events.count) entries; the full log is on your clipboard)"] : []
        return ([summary] + note + kept).joined(separator: "\n")
    }

    /// The last two hours of NotchQ's own log (fixed codes only), newest last, capped in size.
    static func notchQCollectLog(subsystem: String = Bundle.main.bundleIdentifier ?? NotchQPreferences.applicationIdentifier,
                                 environment: Environment = Environment(), timeout: TimeInterval = 20) -> String {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["show", "--last", "2h", "--style", "compact", "--predicate", "subsystem == \"\(subsystem)\""]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        var data = Data()
        let reader = DispatchGroup(); reader.enter()
        DispatchQueue.global().async { data = output.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        var lines: [String] = []
        if (try? task.run()) != nil {
            if reader.wait(timeout: .now() + timeout) == .timedOut { task.terminate() }
            lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("Timestamp") && $0.contains("event=") }
        }
        let body = lines.isEmpty ? "No NotchQ log entries in the last 2 hours." : lines.suffix(400).joined(separator: "\n")
        return environment.summary + "\n" + body
    }
}
