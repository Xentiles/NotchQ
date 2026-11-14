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
    // A new session's first payload has no rate_limits yet: it is ignored and must not wipe the stored reading.
    do { _ = try connection.notchQIngest(["session_id": "new"], now: now.addingTimeInterval(30)); preconditionFailure("missing limits accepted") } catch {}
    do { _ = try connection.notchQIngest(["rate_limits": [String: Any]()], now: now.addingTimeInterval(30)); preconditionFailure("empty limits accepted") } catch {}
    precondition(connection.notchQCachedReading(maximumAge: .infinity, now: now.addingTimeInterval(30))?.snapshot.remaining == 20, "a payload without limits leaves the reading alone")
    // Each window may be absent on its own: a single window keeps the other, still-valid one.
    let single = try! connection.notchQIngest(["rate_limits": ["five_hour": ["used_percentage": 41.5, "resets_at": 5000]]], now: now.addingTimeInterval(40))
    precondition(single.snapshot.windows.count == 2 && single.snapshot.displayWindow?.remaining == 58 && single.snapshot.windows.first { $0.minutes == 10080 }?.remaining == 20, "single-window payload merges with the stored weekly window")
    precondition(connection.notchQCachedReading(maximumAge: .infinity, now: now.addingTimeInterval(40))?.snapshot.windows.count == 2)
    // Past its reset a window is no longer current: dropped from the cache and from payloads.
    let afterFiveHour = connection.notchQCachedReading(maximumAge: .infinity, now: Date(timeIntervalSince1970: 5001))!
    precondition(afterFiveHour.snapshot.windows.count == 1 && afterFiveHour.snapshot.displayWindow?.minutes == 10080, "expired five-hour window is dropped, weekly kept")
    precondition(connection.notchQCachedReading(maximumAge: .infinity, now: Date(timeIntervalSince1970: 9001)) == nil, "nothing current once every window has reset")
    let weeklyOnly = try! connection.notchQIngest(["rate_limits": ["seven_day": ["used_percentage": 81, "resets_at": 9000]]], now: Date(timeIntervalSince1970: 5002))
    precondition(weeklyOnly.snapshot.windows.count == 1 && weeklyOnly.snapshot.remaining == 19, "an expired stored window is not merged back in")
    precondition(NotchQClaudeConnection.notchQParseStatusLine(["rate_limits": ["five_hour": ["used_percentage": 10, "resets_at": 1999]]], now: now) == nil, "a payload window past its reset is ignored")
    runNotchQUsageMergeChecks()
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


func runNotchQUsageMergeChecks() {
    let now = Date(timeIntervalSince1970: 10_000), reset = Date(timeIntervalSince1970: 20_000), week = Date(timeIntervalSince1970: 500_000)
    func snapshot(_ five: Int?, at fiveReset: Date? = reset, weekly: Int? = nil) -> NotchQUsageSnapshot {
        NotchQUsageSnapshot(windows: (five.map { [NotchQUsageWindow(remaining: $0, minutes: 300, reset: fiveReset)] } ?? []) + (weekly.map { [NotchQUsageWindow(remaining: $0, minutes: 10080, reset: week)] } ?? []))
    }
    func merged(_ current: NotchQUsageSnapshot?, _ incoming: NotchQUsageSnapshot) -> NotchQUsageSnapshot? { NotchQUsageSnapshot.notchQMerged(current: current, incoming: incoming, now: now) }
    func five(_ value: NotchQUsageSnapshot?) -> Int? { value?.windows.first { $0.minutes == 300 }?.remaining }
    precondition(five(merged(nil, snapshot(70))) == 70, "first reading is taken as is")
    // /usage prints whole percents (30% used = 70 left); the status line has decimals (30.4% = 69 left).
    precondition(five(merged(snapshot(69), snapshot(70, at: reset.addingTimeInterval(45)))) == 69, "no step back up between sources within one window period")
    precondition(five(merged(snapshot(70), snapshot(69))) == 69 && five(merged(snapshot(70), snapshot(40))) == 40, "remaining going down is always taken")
    precondition(five(merged(snapshot(40), snapshot(90))) == 90, "a rise larger than rounding is a real change")
    precondition(five(merged(snapshot(3), snapshot(100, at: reset.addingTimeInterval(18_000)))) == 100, "after the reset the new period's value is accepted as is")
    precondition(five(merged(snapshot(69, at: nil), snapshot(70))) == 70 && five(merged(snapshot(69), snapshot(70, at: nil))) == 70, "unknown period: newer observation wins")
    let kept = merged(snapshot(69, weekly: 50), snapshot(68))
    precondition(five(kept) == 68 && kept?.windows.count == 2 && kept?.windows.first { $0.minutes == 10080 }?.remaining == 50, "a window the newer source lacks is kept while current")
    let expired = merged(snapshot(69, at: now.addingTimeInterval(-1), weekly: 50), snapshot(nil, weekly: 49))
    precondition(five(expired) == nil && expired?.windows.count == 1 && expired?.displayWindow?.remaining == 49, "a window past its reset is never carried over")
    precondition(merged(nil, snapshot(10, at: now.addingTimeInterval(-1))) == nil && snapshot(10, at: now).notchQUnexpired(now: now) == nil, "an expired reading is not current")
    print("Passed Claude source-merge checks: rounding, real changes, new period, unknown period, kept and expired windows")
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
    // Renamed headers (Claude Code 2.1.312 calls the session limit the 5-hour limit), warning lines and per-model rows.
    let renamed = "Settings  Status   Config   Usage   Stats\nCurrent 5-hour limit\n12% 12% used\nResets 6pm (Europe/Stockholm)\nApproaching your 5-hour limit\nWeekly limit (all models)\n30% 30% used\nResets Oct 16 at 6pm (Europe/Stockholm)\nWeekly limit (Sonnet only)\n2% 2% used\nr to refresh · Esc to cancel\n"
    let modern = NotchQClaudeUsageParser.notchQParse(renamed, now: evening)!
    precondition(modern.windows.count == 2 && modern.displayWindow?.remaining == 88 && modern.windows[1].remaining == 70 && modern.windows[1].reset == notchQAt(2026, 10, 16, 18), "5-hour and weekly wording, footer with extra keys, per-model row ignored")
    for heading in ["5-hour limit", "Current 5-hour window", "Session limit", "Current session"] {
        precondition(NotchQClaudeUsageParser.notchQParse("\(heading)\n7% used\nEsc to cancel\n")?.displayWindow?.minutes == 300, "five-hour heading: \(heading)")
    }
    for heading in ["Current week (all models)", "Current week", "Weekly limit", "7-day limit (all models)"] {
        precondition(NotchQClaudeUsageParser.notchQParse("\(heading)\n7% used\nEsc to cancel\n")?.displayWindow?.minutes == 10080, "weekly heading: \(heading)")
    }
    precondition(NotchQClaudeUsageParser.notchQParse("Current week (Sonnet only)\n7% used\nEsc to cancel\n") == nil, "a per-model row alone is not the account's weekly limit")
    precondition(NotchQClaudeUsageParser.notchQParse("Current session\n93% left\nEsc to cancel\n")?.remaining == 93, "a remaining figure is read as remaining")
    // The screen Claude Code 2.1.295 really draws when the CLI is signed out: complete, but without plan limits.
    let signedOut = "[Screen Reader Mode: on via flag]\nClaude Code v2.1.295\nOpus 5.5 · API Usage Billing\n~/Library/Application Support/NotchQ/UsageCheck\nyou: /usage\nSettings  Status   Config   Usage   Stats\nSession\nTotal cost:            $0.0000\nTotal duration (API):  0s\nTotal duration (wall): 0s\nTotal code changes:    0 lines added, 0 lines removed\nUsage:                 0 input, 0 output, 0 cache read, 0 cache write\nEsc to cancel\n"
    if case .noPlanLimits? = NotchQClaudeUsageParser.notchQClassify(signedOut) {} else { preconditionFailure("signed-out /usage screen is recognized as having no plan limits") }
    // Captured again from 2.1.295 on 2026-11-13 (folder shortened): the trust prompt, then the same screen with the status row's sign-in hint.
    let trustPrompt = "[Screen Reader Mode: on via flag]\nPermission Required: Accessing workspace:\n~/Library/Application Support/NotchQ/UsageCheck\nQuick safety check: Is this a project you created or one you trust?\ny. Yes, I trust this folder\nn. No, exit\nEnter y/n:\nEnter to confirm · Esc to cancel\n"
    precondition(NotchQClaudeUsageParser.notchQClassify(trustPrompt) == nil, "the folder-trust prompt is not a /usage layout")
    let signedOutLive = trustPrompt + "Claude Code v2.1.295\nOpus 5.5 · API Usage Billing\n~/Library/Application Support/NotchQ/UsageCheck\nyou: /usage\nProofing…\nauto mode on (shift+tab to cycle)  ·  esc to interrupt\nNot logged in · Run /login\neffort: medium · /effort\nSettings  Status   Config   Usage   Stats\nSession\nTotal cost:            $0.0000\nTotal duration (API):  0s\nTotal duration (wall): 3s\nTotal code changes:    0 lines added, 0 lines removed\nUsage:                 0 input, 0 output, 0 cache read, 0 cache write\nEsc to cancel\n"
    if case .noPlanLimits? = NotchQClaudeUsageParser.notchQClassify(signedOutLive) {} else { preconditionFailure("the live signed-out screen after the trust prompt has no plan limits") }
    if case .unrecognized? = NotchQClaudeUsageParser.notchQClassify("Plan usage\nFive hours: 12 percent of limit\nEsc to cancel\n") {} else { preconditionFailure("a drawn but unknown layout is reported as such") }
    precondition(NotchQClaudeUsageParser.notchQClassify("Plan usage\nFive hours: 12 percent") == nil && NotchQClaudeUsageParser.notchQClassify(signedOut + "Loading usage...\n") == nil, "an unfinished screen is not classified")
    // Stale figures are never a reading, whatever else the screen shows.
    let stale = text + "Showing last-known usage as of 5m ago (rate limited until 3:14am)\nr to retry · Esc to cancel\n"
    if case .stale? = NotchQClaudeUsageParser.notchQClassify(stale) {} else { preconditionFailure("last-known figures are stale") }
    precondition(NotchQClaudeUsageParser.notchQParse(stale) == nil, "stale last-known figures are never returned as a reading")
    precondition(NotchQClaudeUsageParser.notchQRateLimitEnd(stale, now: evening, timeZone: stockholm) == notchQAt(2026, 10, 10, 3, 14), "rate limit end after midnight")
    precondition(NotchQClaudeUsageParser.notchQRateLimitEnd("rate limited until 9:45pm", now: evening, timeZone: stockholm) == notchQAt(2026, 10, 9, 21, 45) && NotchQClaudeUsageParser.notchQRateLimitEnd("Rate limited until 22:05", now: evening, timeZone: stockholm) == notchQAt(2026, 10, 9, 22, 5), "12- and 24-hour clock")
    precondition(NotchQClaudeUsageParser.notchQRateLimitEnd("rate limited until 5pm (America/New_York)", now: evening, timeZone: stockholm) == Date(timeIntervalSince1970: 1791579600), "a stated zone is honored")
    for vague in ["rate limited — try again in a moment", "rate limited until later", "rate limited until 99:99", "rate limited until 7"] {
        precondition(NotchQClaudeUsageParser.notchQRateLimitEnd(vague, now: evening, timeZone: stockholm) == nil, "no end time is invented: \(vague)")
    }
    precondition(NotchQDiagnostics.notchQReason(for: NotchQClaudeUsageClient.unrecognizedMessage) == .layout && NotchQDiagnostics.notchQReason(for: NotchQClaudeUsageClient.noPlanLimitsMessage) == .apiBilling, "distinct reason codes")
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
    client.executableOverride = server; client.timeout = 1.0; client.emptyScreenSettle = 0.2
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
    if case .failure(let error) = notchQFetch("until") { precondition(error.retryAfter != nil && error.retryAt != nil && error.retryAt!.timeIntervalSinceNow > -60 && error.retryAt!.timeIntervalSinceNow <= 86_400, "the stated end of the rate limit is passed on") } else { preconditionFailure("rate limit with an end time") }
    client.notchQStop(wait: true)
    if case .success(let value) = notchQFetch("renamed") { precondition(value.displayWindow?.remaining == 88 && value.windows.count == 2 && value.windows[1].remaining == 70, "renamed 5-hour and weekly headers") } else { preconditionFailure("renamed /usage headers") }
    client.notchQStop(wait: true)
    let signedOutStart = Date()
    if case .failure(let error) = notchQFetch("signedout") { precondition(error.description == NotchQClaudeUsageClient.noPlanLimitsMessage && Date().timeIntervalSince(signedOutStart) < 0.9, "signed-out screen is explained without waiting for the timeout") } else { preconditionFailure("signed-out /usage screen") }
    client.notchQStop(wait: true)
    if case .failure(let error) = notchQFetch("layout") { precondition(error.description == NotchQClaudeUsageClient.unrecognizedMessage, "unknown layout is not reported as a timeout") } else { preconditionFailure("unrecognized /usage layout") }
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
    runNotchQClaudeStatusLineChecks(server)
    runNotchQClaudeSignInChecks(server)
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

/// The status-line bridge as a live source beside /usage: newer readings apply on the regular timer,
/// sources do not make the badge step back up, and a rate-limited /usage does not blank a fresh reading.
func runNotchQClaudeStatusLineChecks(_ server: URL) {
    _ = NSApplication.shared
    let defaults = NotchQPreferences.defaults, domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-statusline-" + UUID().uuidString)
    let connection = NotchQClaudeConnection(directory: directory, configuration: directory.appendingPathComponent("settings.json"))
    defer {
        if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) } else { defaults.removePersistentDomain(forName: domain) }
        try? FileManager.default.removeItem(at: directory)
    }
    defaults.set(true, forKey: "claudeEnabled"); defaults.set(false, forKey: "codexEnabled"); defaults.set(false, forKey: "onlyRunningApps")
    let delegate = NotchQAppDelegate(claudeConnection: connection)
    delegate.testingLifecycle = true; delegate.testPresence = [.claude]
    delegate.claudeClient.executableOverride = server; delegate.claudeClient.timeout = 1
    let mode = server.appendingPathExtension("mode")
    func settle() {
        let end = Date().addingTimeInterval(4)
        while (delegate.claudeClient.busy || !delegate.manualRefreshPending.isEmpty) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    func started() -> Int { NotchQDiagnostics.shared.entries.filter { $0.event == .requestStarted && $0.provider == .claude }.count }
    try! "changed".write(to: mode, atomically: true, encoding: .utf8)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    settle()
    precondition(delegate.claudeState.percentage == "80%" && delegate.claudeReadWasPolled, "first reading comes from /usage")
    // The mock's five-hour window resets at "6pm (Europe/Stockholm)"; the status line reports the same period to the second.
    let period = NotchQClaudeUsageParser.notchQResetDate("6pm (Europe/Stockholm)")!.timeIntervalSince1970
    func limits(_ used: Double, reset: Double) -> [String: Any] { ["rate_limits": ["five_hour": ["used_percentage": used, "resets_at": reset]], "cost": ["total_api_duration_ms": used]] }
    _ = try! connection.notchQIngest(limits(20.6, reset: period + 30))
    let checks = started()
    delegate.notchQPollUsage()   // the regular 10-second timer tick
    precondition(delegate.claudeState.percentage == "79%" && !delegate.claudeReadWasPolled && delegate.claudeState.error == nil, "a newer status-line reading is applied on the timer")
    precondition(started() == checks && !delegate.claudeClient.busy, "applying it does not bring the next /usage check forward")
    precondition(delegate.notchQProviderStatusMessage(.claude).contains("status-line") && !delegate.notchQProviderStatusMessage(.claude).contains("checked every"), "status text names the status line as the source")
    delegate.menuWillOpen(delegate.item.menu!)
    precondition(delegate.item.menu!.items.contains { $0.title == "Source: Claude Code status line" }, "the dropdown names the source")
    delegate.menuDidClose(delegate.item.menu!)
    delegate.notchQPollUsage()
    precondition(delegate.claudeState.percentage == "79%" && !delegate.claudeReadWasPolled, "an unchanged cache is not applied twice")
    do { _ = try connection.notchQIngest(["session_id": "new"]); preconditionFailure("payload without limits accepted") } catch {}
    precondition(connection.notchQCachedReading() != nil, "a new session's first payload does not wipe the reading")
    // /usage rounds the same usage to 80% left; the badge must not step back up within the period.
    delegate.notchQRefreshUsage(); settle()
    precondition(delegate.claudeReadWasPolled && delegate.claudeState.percentage == "79%", "no upward step when /usage rounds differently")
    delegate.menuWillOpen(delegate.item.menu!)
    precondition(delegate.item.menu!.items.contains { $0.title == "Source: Claude Code /usage check" })
    delegate.menuDidClose(delegate.item.menu!)
    // A reset: the status line reports the next period, which is accepted as is.
    _ = try! connection.notchQIngest(limits(5, reset: period + 18_000))
    delegate.notchQPollUsage()
    precondition(delegate.claudeState.percentage == "95%" && !delegate.claudeReadWasPolled, "after a reset the new period's value is accepted")
    // /usage is rate limited and says until when: the fresh status-line reading stays instead of "—%".
    try! "until".write(to: mode, atomically: true, encoding: .utf8)
    delegate.notchQRefreshUsage(); settle()
    precondition(delegate.claudeState.percentage == "95%" && delegate.claudeState.error == nil && delegate.notch!.button.attributedTitle.string == "95%", "a fresh status-line reading is shown while /usage is rate limited")
    precondition(delegate.claudePollFailure?.contains("rate limiting") == true && delegate.notchQProviderStatusMessage(.claude).contains("/usage: Claude’s usage service is rate limiting"), "the status text still reports the /usage rate limit")
    let wait = delegate.claudeState.throttledUntil.timeIntervalSinceNow
    precondition(wait > 50 && wait <= 3600 && delegate.claudeCadence.level == 0 && delegate.claudeState.nextAllowed >= delegate.claudeState.throttledUntil, "the stated end of the rate limit sets the wait, within bounds, without a guessed backoff")
    precondition(NotchQDiagnostics.shared.entries.last { ($0.event == .failed || $0.event == .succeeded) && $0.provider == .claude }?.reason == .throttled, "the log records the failed /usage check, not a success")
    _ = try! connection.notchQIngest(limits(6.2, reset: period + 18_000))
    let limited = started()
    delegate.notchQPollUsage()
    precondition(delegate.claudeState.percentage == "93%" && started() == limited && delegate.claudeState.throttledUntil.timeIntervalSinceNow > 50, "status-line updates continue during the rate limit and never lift it")
    // Once that reading is no longer recent, the /usage failure is shown rather than an aging number.
    delegate.claudeState.updated = Date().addingTimeInterval(-NotchQPreferences.claudeMaximumAge - 1)
    delegate.notchQExpireClaudeWindows()
    precondition(delegate.claudeState.percentage == "—%" && delegate.claudeState.error!.contains("rate limiting"), "an old stand-in reading gives way to the /usage error")
    // A displayed window whose reset time has passed is not current, and asks for a check as soon as allowed.
    delegate.claudeState.notchQRecordSuccess(NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: 12, minutes: 300, reset: Date().addingTimeInterval(-1)), NotchQUsageWindow(remaining: 60, minutes: 10080, reset: Date().addingTimeInterval(86_400))]))
    let throttled = Date().addingTimeInterval(600)
    delegate.claudeReadWasPolled = false
    delegate.claudeState.throttledUntil = throttled; delegate.claudeState.nextAllowed = Date().addingTimeInterval(3000)
    delegate.notchQExpireClaudeWindows()
    precondition(delegate.claudeState.percentage == "—%" && delegate.claudeState.error!.contains("5-hour limit reset") && delegate.claudeState.snapshot?.windows.count == 1, "an expired window is not shown as current")
    precondition(delegate.claudeState.nextAllowed == throttled, "the follow-up check respects an active rate limit")
    // Right after a /usage check, Claude Code may still print the old reset; that must not start a check every 10 seconds.
    delegate.claudeState.notchQRecordSuccess(NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: 12, minutes: 300, reset: Date().addingTimeInterval(-1))]))
    let regular = Date().addingTimeInterval(120)
    delegate.claudeReadWasPolled = true; delegate.claudeState.nextAllowed = regular
    delegate.notchQExpireClaudeWindows()
    precondition(delegate.claudeState.percentage == "—%" && delegate.claudeState.nextAllowed == regular, "a reading taken seconds ago is not re-asked at once")
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    NSStatusBar.system.removeStatusItem(delegate.item)
    print("Passed Claude status-line checks: live apply, source text, no upward step, new period, rate-limit stand-in, stated wait, expiry")
}

/// The "Sign in to Claude Code…" action: the signed-out state, where the action is offered, the Terminal
/// script, and the wait for `claude auth status`. Everything that would start a real sign-in is replaced.
func runNotchQClaudeSignInChecks(_ server: URL) {
    _ = NSApplication.shared
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("notchq-signin-" + UUID().uuidString)
    // Script contents: only the quoted absolute path and the fixed arguments.
    let awkward = URL(fileURLWithPath: "/Users/someone/My Tools/it's $HOME `x`/claude")
    precondition(NotchQClaudeSignIn.notchQShellQuoted(awkward.path) == "'/Users/someone/My Tools/it'\\''s $HOME `x`/claude'", "single quotes are escaped, everything else is literal")
    precondition(NotchQClaudeSignIn.notchQScript(executable: awkward, arguments: ["auth", "login"]) == "#!/bin/sh\nexec '/Users/someone/My Tools/it'\\''s $HOME `x`/claude' auth login\n", "script is the quoted path and auth login")
    precondition(NotchQClaudeSignIn.notchQScript(executable: awkward, arguments: []) == "#!/bin/sh\nexec '/Users/someone/My Tools/it'\\''s $HOME `x`/claude'\n", "plain claude for a CLI without auth login")
    // Run a generated script against a stand-in CLI in a folder with a space, a quote and shell characters.
    let tools = directory.appendingPathComponent("My Tools/it's $HOME `x`"), fake = tools.appendingPathComponent("claude"), record = directory.appendingPathComponent("ran.txt")
    try! manager.createDirectory(at: tools, withIntermediateDirectories: true)
    try! "#!/bin/sh\nprintf '%s|' \"$@\" > \"$NOTCHQ_RECORD\"\n".write(to: fake, atomically: true, encoding: .utf8)
    try! manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
    let signIn = NotchQClaudeSignIn(directory: directory.appendingPathComponent("support"))
    let script = try! signIn.notchQWriteScript(executable: fake, arguments: ["auth", "login"])
    func mode(_ url: URL) -> Int { (try! manager.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
    precondition(script.lastPathComponent == NotchQClaudeSignIn.scriptName && script.pathExtension == "command" && mode(script) == 0o700 && mode(script.deletingLastPathComponent()) == 0o700, "owner-only script in the private folder")
    let run = Process(); run.executableURL = script; run.environment = ["NOTCHQ_RECORD": record.path, "PATH": "/nonexistent"]
    try! run.run(); run.waitUntilExit()
    precondition(run.terminationStatus == 0 && (try! String(contentsOf: record, encoding: .utf8)) == "auth|login|", "the script runs the located CLI by absolute path, without PATH")
    // Written again it is replaced, and a link left in its place is removed rather than followed.
    let elsewhere = directory.appendingPathComponent("elsewhere.txt")
    try! "keep".write(to: elsewhere, atomically: true, encoding: .utf8)
    try! manager.removeItem(at: script); try! manager.createSymbolicLink(at: script, withDestinationURL: elsewhere)
    let plain = try! signIn.notchQWriteScript(executable: fake, arguments: [])
    precondition((try! String(contentsOf: elsewhere, encoding: .utf8)) == "keep" && (try! manager.attributesOfItem(atPath: plain.path)[.type] as? FileAttributeType) == .typeRegular && !(try! String(contentsOf: plain, encoding: .utf8)).contains("auth") && mode(plain) == 0o700, "the script is overwritten; a link is not followed")
    // `claude auth status`: only loggedIn is read.
    func loggedIn(_ text: String) -> Bool? { NotchQClaudeSignIn.notchQParseLoggedIn(Data(text.utf8)) }
    precondition(loggedIn("{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"email\":\"someone@example.com\"}") == true && loggedIn("{\"loggedIn\": false, \"authMethod\": \"none\"}") == false, "loggedIn is read")
    for odd in ["", "not json", "[]", "{}", "{\"loggedIn\":1}", "{\"loggedIn\":\"true\"}", "{\"loggedin\":true}"] { precondition(loggedIn(odd) == nil, "no sign-in state is guessed from: \(odd)") }
    precondition(NotchQClaudeSignIn.notchQHelpNamesAuthLogin(Data("Usage: claude auth login [options]\n\nSign in to your Anthropic account\n".utf8)) && !NotchQClaudeSignIn.notchQHelpNamesAuthLogin(Data("Usage: claude [options] [command] [prompt]\n".utf8)) && !NotchQClaudeSignIn.notchQHelpNamesAuthLogin(Data()), "auth login support comes from its own help text")
    precondition(NotchQClaudeUsageClient.notchQNeedsSignIn(NotchQClaudeUsageClient.signedOutMessage) && NotchQClaudeUsageClient.notchQNeedsSignIn(NotchQClaudeUsageClient.noPlanLimitsMessage) && !NotchQClaudeUsageClient.notchQNeedsSignIn(NotchQClaudeUsageClient.unrecognizedMessage) && !NotchQClaudeUsageClient.notchQNeedsSignIn("Claude usage check timed out. Sign in to Claude Code; terminal output may be incompatible. Retrying automatically."), "only the signed-out failures ask for a sign-in")
    precondition(NotchQDiagnostics.notchQReason(for: NotchQAppDelegate.claudeSignedOutMessage) == .signedOut)

    // Settings: the button is shown only in the signed-out state and reports clicks.
    let connection = NotchQClaudeConnection(directory: directory.appendingPathComponent("bridge"), configuration: directory.appendingPathComponent("settings.json"))
    let controller = NotchQSettingsController(connection: connection, updater: NotchQUpdater())
    var clicks = 0
    controller.onSignInClaude = { clicks += 1 }
    precondition(controller.signIn.title == "Sign in to Claude Code…" && controller.signInRow.isHidden, "hidden while signed in")
    controller.notchQRefreshSettings(claudeMessage: NotchQAppDelegate.claudeSignedOutMessage, claudeNeedsSignIn: true)
    precondition(!controller.signInRow.isHidden && controller.signIn.isEnabled, "shown when signed out")
    controller.signIn.performClick(nil)
    controller.notchQRefreshSettings(claudeMessage: NotchQClaudeSignIn.waitingMessage, claudeNeedsSignIn: true, signingIn: true)
    precondition(clicks == 1 && !controller.signInRow.isHidden && !controller.signIn.isEnabled, "one sign-in at a time")
    controller.notchQRefreshSettings()
    precondition(controller.signInRow.isHidden, "hidden again after a reading")
    controller.window.close()

    // The app: state flag, menu item, waiting text, and the check that follows a sign-in.
    let defaults = NotchQPreferences.defaults, domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    defer {
        if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) } else { defaults.removePersistentDomain(forName: domain) }
        try? manager.removeItem(at: directory)
    }
    defaults.set(true, forKey: "claudeEnabled"); defaults.set(false, forKey: "codexEnabled"); defaults.set(false, forKey: "onlyRunningApps")
    let delegate = NotchQAppDelegate(claudeConnection: connection)
    delegate.testingLifecycle = true; delegate.testPresence = [.claude]
    delegate.claudeClient.executableOverride = server; delegate.claudeClient.timeout = 1; delegate.claudeClient.emptyScreenSettle = 0.2
    var opened: [URL] = [], supported = true, signedIn = false, canOpen = true, probes = 0
    delegate.claudeSignIn.directory = directory.appendingPathComponent("app-support")
    delegate.claudeSignIn.interval = 0.05
    delegate.claudeSignIn.open = { opened.append($0); return canOpen }
    delegate.claudeSignIn.supportsAuthLogin = { _, done in done(supported) }
    delegate.claudeSignIn.probe = { _, done in probes += 1; done(signedIn) }
    let modeFile = server.appendingPathExtension("mode")
    func settle() {
        let end = Date().addingTimeInterval(4)
        while (delegate.claudeClient.busy || !delegate.manualRefreshPending.isEmpty) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    func wait(_ done: () -> Bool) { let end = Date().addingTimeInterval(4); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
    func check(_ kind: String) { try! kind.write(to: modeFile, atomically: true, encoding: .utf8); delegate.claudeState.notchQPrepareManualRefresh(); delegate.notchQRefreshUsage(); settle() }
    func menuItem() -> NSMenuItem? {
        delegate.menuWillOpen(delegate.item.menu!); defer { delegate.menuDidClose(delegate.item.menu!) }
        return delegate.item.menu!.items.first { $0.title == "Sign in to Claude Code…" }
    }
    try! "changed".write(to: modeFile, atomically: true, encoding: .utf8)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)); settle()
    precondition(delegate.claudeState.percentage == "80%" && !delegate.claudeNeedsSignIn && menuItem() == nil, "no sign-in action while readings arrive")
    delegate.notchQSignInClaude()
    precondition(opened.isEmpty && !delegate.claudeSignIn.waiting, "the action does nothing unless Claude Code is signed out")
    for (kind, reason) in [("layout", NotchQDiagnostics.Reason.layout), ("timeout", .timeout)] {
        check(kind)
        precondition(!delegate.claudeNeedsSignIn && menuItem() == nil && NotchQDiagnostics.shared.entries.last { $0.event == .failed && $0.provider == .claude }?.reason == reason, "\(kind) is not a sign-in problem")
    }
    check("auth")
    precondition(delegate.claudeNeedsSignIn && delegate.notchQProviderStatusMessage(.claude) == NotchQAppDelegate.claudeSignedOutMessage && NotchQDiagnostics.shared.entries.last { $0.event == .failed && $0.provider == .claude }?.reason == .signedOut, "\"Not logged in\" sets the state")
    check("changed")
    precondition(!delegate.claudeNeedsSignIn && delegate.claudeState.percentage == "80%" && menuItem() == nil, "a reading clears the state")
    check("signedout")
    precondition(delegate.claudeNeedsSignIn && delegate.claudeState.percentage == "—%" && delegate.notchQProviderStatusMessage(.claude) == "Claude Code is signed out. Sign in with your Pro or Max account to show usage.", "the screen without plan limits sets the state and the plain text")
    precondition(NotchQDiagnostics.shared.entries.last { $0.event == .failed && $0.provider == .claude }?.reason == .apiBilling, "the log keeps the specific reason")
    precondition(menuItem()?.isEnabled == true && menuItem()?.action == #selector(NotchQAppDelegate.notchQSignInClaude), "the menu offers the sign-in")

    // Start: Terminal gets the script; the status says what is being waited for; only one runs.
    delegate.notchQSignInClaude(); delegate.notchQSignInClaude()
    precondition(opened.count == 1 && delegate.claudeSignIn.waiting && opened[0].lastPathComponent == NotchQClaudeSignIn.scriptName, "one script is opened, once")
    precondition((try! String(contentsOf: opened[0], encoding: .utf8)) == "#!/bin/sh\nexec " + NotchQClaudeSignIn.notchQShellQuoted(server.path) + " auth login\n" && server.path.hasPrefix("/"), "it runs the located CLI by absolute path")
    precondition(delegate.notchQProviderStatusMessage(.claude) == "Waiting for sign-in to finish in your browser…" && menuItem()?.isEnabled == false, "waiting text; the action is disabled meanwhile")
    wait { probes >= 2 }
    precondition(probes >= 2 && delegate.claudeSignIn.waiting && delegate.claudeNeedsSignIn, "keeps asking while signed out")
    // Signed in: the flag clears and /usage is asked at once.
    try! "changed".write(to: modeFile, atomically: true, encoding: .utf8)
    precondition(delegate.claudeState.percentage == "—%" && delegate.claudeState.nextAllowed.timeIntervalSinceNow > 60, "the next regular check is minutes away")
    signedIn = true
    wait { !delegate.claudeSignIn.waiting }
    precondition(delegate.claudeClient.busy, "after the sign-in a usage check starts immediately")
    settle()
    precondition(!delegate.claudeNeedsSignIn && delegate.claudeState.percentage == "80%" && menuItem() == nil, "that check's reading is shown and the action is gone")

    // An active rate limit still has to run out before that check.
    check("signedout"); signedIn = false
    let limited = Date().addingTimeInterval(600)
    delegate.claudeState.throttledUntil = limited; delegate.claudeState.nextAllowed = limited
    delegate.notchQSignInClaude(); wait { opened.count == 2 }
    signedIn = true
    wait { !delegate.claudeSignIn.waiting }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    precondition(!delegate.claudeNeedsSignIn && !delegate.claudeClient.busy && delegate.claudeState.nextAllowed == limited && delegate.claudeState.percentage == "—%", "the follow-up check respects an active rate limit")
    delegate.claudeState.throttledUntil = .distantPast

    // Older CLI without `auth login`: plain claude, and the text says to type /login.
    check("signedout"); signedIn = false; supported = false
    delegate.notchQSignInClaude()
    precondition((try! String(contentsOf: opened.last!, encoding: .utf8)) == "#!/bin/sh\nexec " + NotchQClaudeSignIn.notchQShellQuoted(server.path) + "\n" && delegate.notchQProviderStatusMessage(.claude).contains("Type /login"), "fallback for a CLI without auth login")
    // Sleep ends the wait; nothing is left running.
    delegate.menuWillOpen(delegate.item.menu!)
    precondition(delegate.menuTimer != nil)
    delegate.notchQWillSleep()
    precondition(!delegate.claudeSignIn.waiting && delegate.menuTimer == nil, "sleep stops the wait and the open menu's timer")
    delegate.notchQDidWake(); supported = true
    check("signedout")
    // Giving up after the limit leaves the state and the action in place.
    delegate.claudeSignIn.limit = 0.12
    delegate.notchQSignInClaude(); wait { !delegate.claudeSignIn.waiting }
    precondition(delegate.claudeNeedsSignIn && delegate.notchQProviderStatusMessage(.claude) == NotchQAppDelegate.claudeSignedOutMessage && menuItem()?.isEnabled == true, "a sign-in that never finishes times out")
    // Terminal could not be opened.
    canOpen = false; delegate.claudeSignIn.limit = 300
    delegate.notchQSignInClaude()
    precondition(!delegate.claudeSignIn.waiting && delegate.claudeNeedsSignIn && delegate.notchQProviderStatusMessage(.claude).contains("Could not open Terminal"), "a failed start is reported")
    canOpen = true; delegate.notchQSignInClaude()
    delegate.menuWillOpen(delegate.item.menu!)
    precondition(delegate.claudeSignIn.waiting && delegate.menuTimer != nil)
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    precondition(!delegate.claudeSignIn.waiting && delegate.menuTimer == nil, "quitting stops the wait and the menu timer")
    NSStatusBar.system.removeStatusItem(delegate.item)
    print("Passed Claude sign-in checks: state flag, menu and Settings action, Terminal script quoting and permissions, auth-status parsing, wait, rate limit, timeout, sleep and quit")
}
