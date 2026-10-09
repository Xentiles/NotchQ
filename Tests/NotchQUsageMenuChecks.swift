import AppKit

func runNotchQUsageMenuChecks() {
    let now = Date(timeIntervalSince1970: 1000)
    let zone = TimeZone(identifier: "Etc/UTC")!
    let weekly = NotchQUsageWindow(remaining: 13, minutes: 10080, reset: now)
    let fiveHour = NotchQUsageWindow(remaining: 99, minutes: 300, reset: nil, resetDescription: "6pm (Etc/UTC)")
    var state = NotchQUsageState()
    state.notchQRecordSuccess(NotchQUsageSnapshot(windows: [weekly, fiveHour]), now: now)
    let rows = notchQUsageMenuRows(state, now: now, timeZone: zone)
    precondition(rows[0] == "5-hour: 99% left" && rows[1] == "Weekly: 13% left", "short window above weekly regardless of source order")
    precondition(rows[2] == "5-hour resets: 6pm" && rows[3].hasPrefix("Weekly resets:"), "reset rows follow all usage rows in matching order; the viewer's own zone is not labelled")
    precondition(notchQLocalResetText("6pm (Asia/Tokyo)", timeZone: zone) == "6pm (Asia/Tokyo)", "unparsed text from another zone keeps its label")
    let converted = NotchQUsageWindow(remaining: 50, minutes: 300, reset: Date(timeIntervalSince1970: 7200), resetDescription: "4am (Europe/Stockholm)")
    var claudeLike = NotchQUsageState(); claudeLike.notchQRecordSuccess(NotchQUsageSnapshot(windows: [converted]), now: now)
    let shown = notchQUsageMenuRows(claudeLike, now: now, timeZone: zone)[1]
    precondition(shown.hasPrefix("5-hour resets: ") && !shown.contains("Stockholm") && shown.contains("2:00"), "Claude resets display like Codex, in the viewer's zone")
    precondition(rows[4] == "Last updated: 00:16:40", "exact 24-hour HH:mm:ss")
    state.notchQRecordSuccess(NotchQUsageSnapshot(windows: [weekly]), now: now)
    let weeklyRows = notchQUsageMenuRows(state, now: now, timeZone: zone)
    precondition(weeklyRows.count == 3 && !weeklyRows.contains { $0.contains("5-hour") }, "absent window and its reset stay hidden")
    state.notchQRecordSuccess(NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: 0, minutes: 300, reset: nil)]), now: now)
    precondition(notchQUsageMenuRows(state, now: now, timeZone: zone)[1] == "5-hour resets: unavailable", "available window with missing reset is explicit")
    state.notchQRecordFailure("Offline", now: now)
    let staleRows = notchQUsageMenuRows(state, now: now, timeZone: zone)
    precondition(staleRows.contains("Last known 5-hour: 0% left") && staleRows.contains("Last updated: 00:16:40 (last successful check)"), "errors never present cached data as current")
    let delegate = NotchQAppDelegate()
    delegate.providers = [.codex, .claude]
    delegate.state.notchQRecordSuccess(NotchQUsageSnapshot(windows: [weekly, fiveHour]), now: now)
    delegate.claudeState = delegate.state
    let menu = NSMenu(); delegate.menuWillOpen(menu)
    let items = menu.items
    precondition(items[0].title == "NotchQ" && items[1].isSeparatorItem && items[2].title == "Codex — white")
    let claude = items.firstIndex { $0.title == "Claude — orange" }!
    precondition(items[claude - 1].isSeparatorItem)
    precondition(items[3..<(3 + rows.count)].map(\.title) == items[(claude + 1)..<(claude + 1 + rows.count)].map(\.title), "identical provider section structure")
    let settings = items.firstIndex { $0.title == "Settings…" }!
    precondition(items[settings - 1].isSeparatorItem && items.last!.title == "Quit" && items[items.count - 2].isSeparatorItem)
    delegate.providers = [.claude]
    delegate.menuWillOpen(menu)
    precondition(menu.items.first { $0.title == "Refresh now" }!.isEnabled, "Claude-only refresh remains available")
    print("Passed uniform menu checks: ordering, absent windows, resets, exact update time, stale state, separators and Claude-only refresh")
}
