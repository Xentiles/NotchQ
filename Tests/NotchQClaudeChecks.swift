import Foundation
import AppKit

func runNotchQClaudeChecks() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-claude-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("settings.json")
    let connection = NotchQClaudeConnection(directory: directory.appendingPathComponent("cache"), configuration: config)
    let now = Date(timeIntervalSince1970: 2000)
    var payload: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": 30.4, "resets_at": 5000], "seven_day": ["used_percentage": 80, "resets_at": 9000]], "cost": ["total_api_duration_ms": 10], "cwd": "/private/workspace", "session_id": "private"]
    let reading = try! connection.notchQIngest(payload, now: now)
    precondition(reading.snapshot.remaining == 20)
    let duplicate = try! connection.notchQIngest(payload, now: now.addingTimeInterval(10))
    precondition(duplicate.observedAt == now, "timer repeat does not fake freshness")
    precondition(connection.notchQCachedReading(now: now.addingTimeInterval(181)) == nil)
    payload["cost"] = ["total_api_duration_ms": 11]
    precondition(try! connection.notchQIngest(payload, now: now.addingTimeInterval(20)).observedAt == now.addingTimeInterval(20))
    let bytes = try! Data(contentsOf: connection.cacheURL)
    let text = String(data: bytes, encoding: .utf8)!
    precondition(!text.contains("private/workspace") && !text.contains("session_id"), "cache contains no workspace or session identity")
    let mode = try! FileManager.default.attributesOfItem(atPath: connection.cacheURL.path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o600)
    do { _ = try connection.notchQIngest([:]); preconditionFailure("missing limits accepted") } catch {}
    precondition(connection.notchQCachedReading(maximumAge: .infinity, now: now) == nil)
    let original: [String: Any] = ["statusLine": ["type": "command", "command": "printf old", "padding": 2], "other": true]
    try! JSONSerialization.data(withJSONObject: original).write(to: config)
    try! connection.notchQConnect(executable: URL(fileURLWithPath: "/Applications/NotchQ.app/Contents/MacOS/NotchQ"))
    precondition(connection.isConnected && connection.notchQOriginalStatusCommand() == "printf old")
    try! connection.notchQDisconnect()
    let restored = try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    precondition((restored["statusLine"] as! [String: Any])["command"] as! String == "printf old" && restored["other"] as! Bool)
    try! connection.notchQConnect(executable: URL(fileURLWithPath: "/Applications/NotchQ.app/Contents/MacOS/NotchQ"))
    var changed = try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    changed["statusLine"] = ["type": "command", "command": "new user choice"]
    try! JSONSerialization.data(withJSONObject: changed).write(to: config)
    do { try connection.notchQDisconnect(); preconditionFailure("overwrote user change") } catch {}
    runNotchQClaudeUsageParserChecks()
    runNotchQProviderStatusChecks()
    print("Passed Claude connection checks: percentages, freshness, minimization, permissions, backup/restore and conflict preservation")
}


func runNotchQProviderStatusChecks() {
    let defaults = NotchQPreferences.defaults
    let domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-provider-status-" + UUID().uuidString)
    defer {
        if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) }
        else { defaults.removePersistentDomain(forName: domain) }
        try? FileManager.default.removeItem(at: directory)
    }
    let connection = NotchQClaudeConnection(directory: directory.appendingPathComponent("cache"), configuration: directory.appendingPathComponent("settings.json"))
    let delegate = NotchQAppDelegate(claudeConnection: connection)
    defaults.set(false, forKey: "codexEnabled")
    defaults.set(true, forKey: "claudeEnabled")
    defaults.set(true, forKey: "onlyRunningApps")
    delegate.state.error = "Codex is not running."
    precondition(delegate.notchQProviderStatusMessage(.codex).contains("disabled"), "disabled source must not be labelled not running")
    delegate.providers = []
    delegate.notchQUpdateClaudeState()
    precondition(delegate.claudeState.error!.contains("desktop app is not running") && delegate.claudeState.error!.contains("terminal use"), "desktop filter must explain hidden CLI readings")
    defaults.set(false, forKey: "onlyRunningApps")
    delegate.providers = []
    precondition(delegate.notchQProviderStatusMessage(.claude).contains("not found on this Mac") && delegate.notchQProviderStatusMessage(.claude).contains("Choose CLI"), "undetected source explains how to add it")
    delegate.providers = [.claude]
    delegate.notchQUpdateClaudeState()
    precondition(delegate.claudeState.error!.contains("Claude Code was not found") && !delegate.claudeState.error!.contains("Connect"), "no CLI and no fallback asks for Claude Code, not a settings edit")
    precondition(delegate.displayedProviders == [.claude] && delegate.claudeState.percentage == "—%", "detected source stays visible with an unavailable marker")
    try! connection.notchQConnect(executable: URL(fileURLWithPath: "/Applications/NotchQ.app/Contents/MacOS/NotchQ"))
    delegate.notchQUpdateClaudeState()
    precondition(delegate.claudeState.error!.contains("Connection configured") && delegate.claudeState.error!.contains("no current quota reading"), "configured bridge is not a successful reading")
    precondition(delegate.displayedProviders == [.claude] && delegate.claudeState.percentage == "—%", "configured fallback stays visible with an unavailable marker")
    let payload: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": 30, "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970]]]
    _ = try! connection.notchQIngest(payload)
    delegate.notchQUpdateClaudeState()
    precondition(delegate.claudeState.percentage == "70%" && delegate.displayedProviders == [.claude], "fresh terminal-only snapshot displays when desktop filter is off")
    defaults.set(false, forKey: "claudeEnabled")
    delegate.notchQUpdateClaudeState()
    delegate.providers = []
    precondition(delegate.claudeState.error!.contains("disabled") && delegate.displayedProviders.isEmpty, "disabled provider hides even with valid cached data")
    delegate.providers = [.claude]
    defaults.set(true, forKey: "claudeEnabled")
    defaults.set(true, forKey: "codexEnabled")
    defaults.set(false, forKey: "onlyRunningApps")
    delegate.providers = [.codex, .claude]
    let snapshot = NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: 70, minutes: 300, reset: nil)])
    delegate.state.notchQRecordSuccess(snapshot)
    delegate.claudeState.notchQRecordSuccess(snapshot)
    delegate.claudeReadWasPolled = true
    precondition(delegate.notchQProviderStatusMessage(.codex) == "70% remaining; checked every 10 seconds." && delegate.notchQProviderStatusMessage(.claude) == "70% remaining; checked every 2 minutes.", "live status states each provider's cadence")
    delegate.claudeReadWasPolled = false
    precondition(delegate.notchQProviderStatusMessage(.claude).contains("snapshot") && !delegate.notchQProviderStatusMessage(.claude).contains("checked every"), "fallback snapshots do not claim live polling")
    defaults.set(true, forKey: "onlyRunningApps")
    _ = try! connection.notchQIngest(payload, now: Date().addingTimeInterval(-240))
    delegate.notchQUpdateClaudeState()
    precondition(delegate.claudeState.error!.contains("older than three minutes") && delegate.displayedProviders.contains(.claude) && delegate.claudeState.percentage == "—%", "expired reading must explain freshness rather than connection failure")
    print("Passed provider status checks: disabled, desktop filter, disconnected, waiting, fresh and expired snapshots")
}


func runNotchQClaudeUsageParserChecks() {
    let text = "Current session\r\n1% 1% used\r\nResets 6pm (Europe/Stockholm)\r\nCurrent week (all models)\r\n0% 0% used\r\n"
    precondition(NotchQClaudeUsageParser.notchQParse(text + "Esc to cancel\r\n")?.remaining == 99)
    precondition(NotchQClaudeUsageParser.notchQParse("\u{001B}[2K" + text + "Esc to cancel\r\n")?.remaining == 99)
    precondition(NotchQClaudeUsageParser.notchQParse(text.replacingOccurrences(of: "1% 1%", with: "1.8% 1.8%") + "Esc to cancel\r\n")?.remaining == 98)
    precondition(NotchQClaudeUsageParser.notchQParse("Current session\n1% used") == nil)
    precondition(NotchQClaudeUsageParser.notchQParse("Not logged in") == nil)
    let resets = text + "Resets Oct 16, 6pm (Europe/Stockholm)\r\nEsc to cancel\r\n"
    let snapshot = NotchQClaudeUsageParser.notchQParse(resets)!
    precondition(snapshot.windows[0].resetDescription == "6pm (Europe/Stockholm)")
    precondition(snapshot.windows[1].resetDescription == "Oct 16, 6pm (Europe/Stockholm)")
    precondition(NotchQClaudeUsageParser.notchQParse(text + "Esc to cancel\r\n")?.windows[1].resetDescription == nil, "missing reset is never invented")
    // Reset text becomes a real instant, so the menu can show it in the viewer's own zone.
    let stockholm = TimeZone(identifier: "Europe/Stockholm")!
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = stockholm
    func notchQAt(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))! }
    let evening = notchQAt(2026, 10, 9, 21, 30)
    precondition(NotchQClaudeUsageParser.notchQResetDate("11pm (Europe/Stockholm)", now: evening) == notchQAt(2026, 10, 9, 23), "time-only reset later today")
    precondition(NotchQClaudeUsageParser.notchQResetDate("1am (Europe/Stockholm)", now: evening) == notchQAt(2026, 10, 10, 1), "time-only reset after midnight is tomorrow")
    precondition(NotchQClaudeUsageParser.notchQResetDate("12:30pm (Europe/Stockholm)", now: evening) == notchQAt(2026, 10, 10, 12, 30) && NotchQClaudeUsageParser.notchQResetDate("12am (Europe/Stockholm)", now: evening) == notchQAt(2026, 10, 10, 0), "12-hour clock edges")
    precondition(NotchQClaudeUsageParser.notchQResetDate("Oct 15 at 5pm (Europe/Stockholm)", now: evening) == notchQAt(2026, 10, 15, 17), "Claude Code 2.1.295 weekly format")
    precondition(NotchQClaudeUsageParser.notchQResetDate("Oct 16, 6pm (Europe/Stockholm)", now: evening) == notchQAt(2026, 10, 16, 18), "comma weekly format")
    precondition(NotchQClaudeUsageParser.notchQResetDate("Jan 2 at 9am (Europe/Stockholm)", now: notchQAt(2026, 12, 30, 12)) == notchQAt(2027, 1, 2, 9), "weekly reset across New Year")
    precondition(NotchQClaudeUsageParser.notchQResetDate("5pm (America/New_York)", now: evening) == Date(timeIntervalSince1970: 1791579600), "other zones convert to the same instant")
    for unreadable in ["in 3 hours", "11pm (Mars/Olympus)", "25pm (Europe/Stockholm)", "Foo 3 at 5pm (Europe/Stockholm)", "11pm"] {
        precondition(NotchQClaudeUsageParser.notchQResetDate(unreadable, now: evening) == nil, "unreadable reset text is not guessed: \(unreadable)")
    }
    precondition(NotchQClaudeUsageParser.notchQParse(resets, now: evening)!.windows[1].reset == notchQAt(2026, 10, 16, 18), "parsed snapshot carries the reset instant")
    let complete = text + "Esc to cancel\n"
    precondition(NotchQClaudeUsageParser.notchQParse(complete + "Current session\n20% used") == nil, "do not reuse an old frame while a new frame is incomplete")
    let newer = complete.replacingOccurrences(of: "1% 1%", with: "20% 20%")
    precondition(NotchQClaudeUsageParser.notchQParse(complete + newer)?.displayWindow?.remaining == 80, "latest complete frame wins")
    precondition(NotchQClaudeUsageParser.notchQParse("Current week (all models)\n23% used\nEsc to cancel\n")?.displayWindow?.remaining == 77)
    precondition(NotchQClaudeUsageParser.notchQParse("Current session\n101% used\nEsc to cancel\n") == nil)
    print("Passed Claude read-only usage parser checks")
}

func runNotchQClaudeUsageLiveCheck() {
    let client = NotchQClaudeUsageClient()
    var previous: Date?
    for index in 0..<3 {
        if let previous = previous {
            let target = previous.addingTimeInterval(10)
            while Date() < target { RunLoop.main.run(until: min(target, Date().addingTimeInterval(0.1))) }
        }
        let now = Date()
        if let previous = previous { print(String(format: "Claude read interval %.3fs", now.timeIntervalSince(previous))) }
        previous = now
        var result: Result<NotchQUsageSnapshot, NotchQSourceError>?
        client.notchQFetchUsage { result = $0 }
        let end = Date().addingTimeInterval(12)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        switch result {
        case .success(let snapshot):
            precondition(!client.busy && client.processIdentifier == nil)
            print("Read \(index+1): \(snapshot.displayWindow!.label) \(snapshot.displayWindow!.remaining)% remaining; completed=\(Date().timeIntervalSince1970)")
            for window in snapshot.windows { print("  \(window.label): \(window.remaining)% remaining; reset=\(window.resetDescription ?? "unavailable")") }
        case .failure(let error): client.notchQStop(wait: true); print("Live check failed: \(error.description)"); exit(1)
        case .none: client.notchQStop(wait: true); print("Live check callback timed out"); exit(1)
        }
        fflush(stdout)
    }
    client.notchQStop(wait: true)
    print("Claude read-only polling check complete; no model prompts sent")
}


func runNotchQClaudePollingChecks(_ server: URL) {
    let mode = server.appendingPathExtension("mode")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-claude-poll-test-" + UUID().uuidString)
    let client = NotchQClaudeUsageClient(directory: directory)
    client.executableOverride = server; client.timeout = 1.0
    defer { client.notchQStop(wait: true); try? FileManager.default.removeItem(at: mode); try? FileManager.default.removeItem(at: directory) }
    func notchQFetch(_ kind: String) -> Result<NotchQUsageSnapshot, NotchQSourceError> {
        try! kind.write(to: mode, atomically: true, encoding: .utf8)
        var result: Result<NotchQUsageSnapshot, NotchQSourceError>?
        client.notchQFetchUsage { result = $0 }
        let end = Date().addingTimeInterval(3)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(result != nil, "Claude poll callback missing: \(kind)")
        switch result! {
        case .success(let snapshot): print("Claude fixture \(kind): \(snapshot.remaining)%")
        case .failure(let error): print("Claude fixture \(kind): \(error.description)")
        }
        fflush(stdout)
        return result!
    }
    if case .success(let value) = notchQFetch("success") { precondition(value.remaining == 99) } else { preconditionFailure("initial Claude poll") }
    if case .success(let value) = notchQFetch("success") { precondition(value.remaining == 99) } else { preconditionFailure("fresh Claude poll") }
    if case .success(let value) = notchQFetch("changed") { precondition(value.displayWindow?.remaining == 80) } else { preconditionFailure("changed fresh reading") }
    if case .success(let value) = notchQFetch("redraw") { precondition(value.displayWindow?.remaining == 80 && value.windows[1].remaining == 60) } else { preconditionFailure("latest complete redraw") }
    if case .success(let value) = notchQFetch("weekly") { precondition(value.displayWindow?.remaining == 77 && value.windows.count == 1) } else { preconditionFailure("one window") }
    if case .failure = notchQFetch("partial") {} else { preconditionFailure("mixed partial windows") }
    if case .success = notchQFetch("numeric429") {} else { preconditionFailure("version and timing numbers are not service throttling") }
    if case .failure(let error) = notchQFetch("throttle") { precondition(error.retryAfter == 60) } else { preconditionFailure("service throttle") }
    client.notchQStop(wait: true)
    if case .failure(let error) = notchQFetch("ratelimited") { precondition(error.retryAfter != nil, "stale last-known numbers on a rate-limited screen are a throttle, not a reading") } else { preconditionFailure("rate-limited /usage screen") }
    client.notchQStop(wait: true)
    if case .success(let value) = notchQFetch("split-reset") {
        precondition(value.windows[1].resetDescription == "Oct 16, 6pm (Europe/Stockholm)", "retain reset arriving in a later PTY chunk")
    } else { preconditionFailure("split reset poll") }
    client.notchQStop(wait: true)
    if case .failure = notchQFetch("timeout") {} else { preconditionFailure("Claude poll timeout") }
    if case .success = notchQFetch("success") {} else { preconditionFailure("Claude poll recovery") }
    client.notchQStop(wait: true)
    if case .failure = notchQFetch("auth") {} else { preconditionFailure("Claude sign-in error") }
    client.notchQStop(wait: true)
    if case .success = notchQFetch("trust") {} else { preconditionFailure("private folder setup") }
    client.notchQStop(wait: true)
    if case .failure = notchQFetch("cost") {} else { preconditionFailure("unexpected model activity") }
    if case .failure(let error) = notchQFetch("success") { precondition(error.description.contains("Restart NotchQ")) } else { preconditionFailure("model-activity safety latch") }
    let fresh = NotchQClaudeUsageClient(directory: directory); fresh.executableOverride = server; fresh.timeout = 1
    try! "exit".write(to: mode, atomically: true, encoding: .utf8)
    var exited: Result<NotchQUsageSnapshot, NotchQSourceError>?
    fresh.notchQFetchUsage { exited = $0 }
    let exitEnd = Date().addingTimeInterval(3)
    while exited == nil && Date() < exitEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    if case .failure(let error) = exited { precondition(error.description.contains("Claude Code closed") && !error.description.contains("Codex"), "Claude exit is not reported as Codex") } else { preconditionFailure("Claude exit fixture") }
    fresh.notchQStop(wait: true)
    runNotchQManualRefreshChecks(server)
    print("Passed Claude PTY polling checks: persistent reads, timeout, recovery, authentication error, private-folder setup, model-activity guard, shutdown")
}

func runNotchQManualRefreshChecks(_ server: URL) {
    _ = NSApplication.shared
    let defaults = NotchQPreferences.defaults, domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-refresh-" + UUID().uuidString)
    let connection = NotchQClaudeConnection(directory: directory, configuration: directory.appendingPathComponent("settings.json"))
    defer {
        if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) } else { defaults.removePersistentDomain(forName: domain) }
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "claudeEnabled"); defaults.set(false, forKey: "codexEnabled"); defaults.set(false, forKey: "onlyRunningApps")
    // No status-line bridge: polling must work from the detected CLI alone.
    let delegate = NotchQAppDelegate(claudeConnection: connection)
    precondition(!connection.isConnected)
    delegate.testingLifecycle = true; delegate.testPresence = [.claude]
    delegate.claudeClient.executableOverride = server; delegate.claudeClient.timeout = 1
    let mode = server.appendingPathExtension("mode")
    try! "slow".write(to: mode, atomically: true, encoding: .utf8)
    let before = NotchQDiagnostics.shared.entries.filter { $0.event == .requestStarted && $0.provider == .claude }.count
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let untilStarted = Date().addingTimeInterval(0.15)
    RunLoop.main.run(until: untilStarted)
    precondition(delegate.claudeClient.busy)
    try! "changed".write(to: mode, atomically: true, encoding: .utf8)
    delegate.notchQRefreshUsage(); delegate.notchQRefreshUsage()
    precondition(delegate.manualRefreshPending == [.claude], "one coalesced manual request during an active check")
    let end = Date().addingTimeInterval(4)
    while (delegate.claudeClient.busy || !delegate.manualRefreshPending.isEmpty) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    let after = NotchQDiagnostics.shared.entries.filter { $0.event == .requestStarted && $0.provider == .claude }.count
    precondition(after - before == 2 && delegate.claudeState.percentage == "80%", "queued refresh launches exactly one fresh check and updates five-hour headline")
    delegate.notchQAppPresenceChanged()
    precondition(!delegate.claudeClient.busy, "unrelated app launch/quit notifications must not add usage requests")
    precondition(delegate.notch!.button.attributedTitle.string == "80%" && delegate.notchQProviderStatusMessage(.claude).hasPrefix("80%"))
    precondition(delegate.notch!.button.toolTip!.contains("5-hour"))
    delegate.notchQPollUsage()
    precondition(!delegate.claudeClient.busy, "timer polls wait a minute after a Claude reading")
    // Regression: a rate-limited Claude left "Refresh queued…" stuck with no explanation.
    try! "ratelimited".write(to: mode, atomically: true, encoding: .utf8)
    delegate.notchQRefreshUsage()
    let limitedEnd = Date().addingTimeInterval(4)
    while (delegate.claudeClient.busy || !delegate.manualRefreshPending.isEmpty) && Date() < limitedEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(delegate.claudeState.error!.contains("rate limiting") && delegate.claudeState.error!.contains("Showing the") && delegate.claudeCadence.level == 1, "rate limit is explained")
    precondition(delegate.claudeState.holding && delegate.claudeState.percentage == "80%" && delegate.notch!.button.attributedTitle.string == "80%", "the just-read value stays on the badge during a short limit; the stale /usage screen numbers are never used")
    precondition(notchQUsageMenuRows(delegate.claudeState).contains("5-hour: 80% left") && delegate.item.button!.toolTip!.contains("last reading"), "dropdown and tooltip say it's the last reading")
    precondition(NotchQDiagnostics.shared.entries.last { $0.event == .failed && $0.provider == .claude }?.reason == .throttled, "the shareable log records why Claude failed")
    let throttle = delegate.claudeState.throttledUntil
    precondition(throttle.timeIntervalSinceNow > 220 && throttle.timeIntervalSinceNow <= 240, "first rate limit waits four minutes")
    delegate.notchQRefreshUsage(); delegate.notchQRefreshUsage()
    precondition(!delegate.claudeClient.busy && delegate.manualRefreshPending.isEmpty && delegate.claudeState.nextAllowed == throttle, "refresh during a rate limit is not queued and does not retry early")
    delegate.menuWillOpen(delegate.item.menu!)
    precondition(delegate.item.menu!.items.contains { $0.title == "Refresh now" && $0.isEnabled }, "Refresh stays available instead of stuck as queued")
    delegate.menuDidClose(delegate.item.menu!)
    try! "changed".write(to: mode, atomically: true, encoding: .utf8)
    delegate.notchQWillSleep()
    precondition(delegate.manualRefreshPending.isEmpty && delegate.claudeState.percentage == "—%")
    delegate.claudeClient.notchQStop(wait: true)
    precondition(!delegate.claudeClient.busy)
    delegate.claudeState.throttledUntil = .distantPast
    delegate.notchQDidWake()
    let awakeEnd = Date().addingTimeInterval(3)
    while delegate.claudeClient.busy && Date() < awakeEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(delegate.claudeState.percentage == "80%", "wake requests fresh Claude data")
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    precondition(delegate.claudeClient.processIdentifier == nil && !delegate.claudeClient.busy && delegate.manualRefreshPending.isEmpty)
    NSStatusBar.system.removeStatusItem(delegate.item)
    print("Passed Claude manual-refresh checks: coalescing, headline consistency, throttle, sleep/wake and shutdown")
}
