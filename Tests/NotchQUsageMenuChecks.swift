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
    precondition(rows[4] == "Last updated: 00:16:40 (0 s ago)", "exact 24-hour HH:mm:ss, with its age")
    state.notchQRecordSuccess(NotchQUsageSnapshot(windows: [weekly]), now: now)
    let weeklyRows = notchQUsageMenuRows(state, now: now, timeZone: zone)
    precondition(weeklyRows.count == 3 && !weeklyRows.contains { $0.contains("5-hour") }, "absent window and its reset stay hidden")
    state.notchQRecordSuccess(NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: 0, minutes: 300, reset: nil)]), now: now)
    precondition(notchQUsageMenuRows(state, now: now, timeZone: zone)[1] == "5-hour resets: unavailable", "available window with missing reset is explicit")
    state.notchQRecordFailure("Offline", now: now)
    let staleRows = notchQUsageMenuRows(state, now: now, timeZone: zone)
    precondition(staleRows.contains("Last known 5-hour: 0% left") && staleRows.contains("Last updated: 00:16:40 (0 s ago) (last successful check)"), "errors never present cached data as current")
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
    // Colours: the app title at full strength; provider headings, figures and resets in the badge's colours; the rest faded.
    // Coloured rows are view rows (AppKit dims a disabled item's attributed title); faded rows are plain items.
    func tint(_ item: NSMenuItem) -> NSColor? { (item.view as? NotchQMenuRowView).map { $0.text == item.title ? $0.color : .clear } }
    precondition(tint(items[0]) == NotchQMenuPalette.title && items[0].attributedTitle == nil, "the NotchQ title is drawn by its own view in pure white/black, not greyed out")
    // Provider sections below the title: Codex an opaque light (dark) grey, Claude the badge orange at brightness × 0.92.
    let codexTint = NotchQMenuPalette.codex, claudeTint = NotchQMenuPalette.claude
    precondition(tint(items[2]) == codexTint && tint(items[claude]) == claudeTint, "headings: Codex grey, Claude dimmed orange")
    let claudeRows = items[(claude + 1)..<(claude + 1 + rows.count)]
    precondition(claudeRows.filter { $0.title.hasPrefix("5-hour") || $0.title.hasPrefix("Weekly") }.allSatisfy { tint($0) == claudeTint } && claudeRows.filter { $0.title.hasPrefix("5-hour") || $0.title.hasPrefix("Weekly") }.count == 4, "Claude's figures and reset times are orange")
    precondition(items[3..<(3 + rows.count)].filter { $0.title.hasPrefix("5-hour") || $0.title.hasPrefix("Weekly") }.allSatisfy { tint($0) == codexTint }, "Codex's figures and reset times are white")
    precondition(claudeRows.first { $0.title.hasPrefix("Last updated") }.map { $0.attributedTitle == nil && $0.view == nil } == true && NotchQAppDelegate.notchQMenuRowIsTinted("Weekly resets: Nov 30") && !NotchQAppDelegate.notchQMenuRowIsTinted("Last known 5-hour: 0% left") && !NotchQAppDelegate.notchQMenuRowIsTinted("Next check in 9 seconds") && !NotchQAppDelegate.notchQMenuRowIsTinted("Source: Claude Code status line"), "last updated, next check, source and stale figures stay faded")
    let settings = items.firstIndex { $0.title == "Settings…" }!
    precondition(items[settings - 1].isSeparatorItem && items.last!.title == "Quit" && items[items.count - 2].isSeparatorItem)
    precondition([items[settings], items.last!].allSatisfy { $0.attributedTitle == nil && $0.view == nil && $0.isEnabled }, "Settings… and Quit are ordinary, enabled items at full strength")
    delegate.providers = [.claude]
    delegate.menuWillOpen(menu)
    precondition(menu.items.first { $0.title == "Refresh now" }!.isEnabled, "Claude-only refresh remains available")
    runNotchQMenuColourChecks()
    runNotchQLiveMenuChecks()
    runNotchQPulseChecks()
    runNotchQReminderAppChecks()
    print("Passed uniform menu checks: ordering, absent windows, resets, exact update time, stale state, separators and Claude-only refresh")
}

/// The coloured rows' pixels, in a dark and a light menu: the title pure white/black, Codex opaque grey 0.80 (0.20),
/// Claude the opaque orange (217, 119, 87) × 0.92. Sampled from what the row view actually draws.
func runNotchQMenuColourChecks() {
    _ = NSApplication.shared
    let geometry = NotchQMenuGeometry.shared
    precondition(geometry.rowHeight >= 18 && geometry.rowHeight <= 32 && geometry.leadingPadding > 4 && geometry.stateColumn >= 0, "standard row measurements read from AppKit (\(geometry))")
    let checked = NSMenu(); checked.addItem(NSMenuItem(title: "a", action: nil, keyEquivalent: "")); let on = NSMenuItem(title: "b", action: nil, keyEquivalent: ""); on.state = .on; checked.addItem(on)
    let unchecked = NSMenu(); unchecked.addItem(NSMenuItem(title: "a", action: nil, keyEquivalent: "")); let off = NSMenuItem(title: "b", action: nil, keyEquivalent: ""); off.state = .off; unchecked.addItem(off)
    precondition(NotchQMenuGeometry.notchQShowsStateColumn(checked) && !NotchQMenuGeometry.notchQShowsStateColumn(unchecked), "the checkmark column only when an item is on")
    /// The glyph colour: the un-premultiplied colour of the most covered pixels, and that coverage.
    func sample(_ color: NSColor, _ appearance: NSAppearance.Name, text: String = "NotchQ Weekly: 4% left") -> (r: Int, g: Int, b: Int, alpha: CGFloat) {
        let view = NotchQMenuRowView(text: text, color: color, leftInset: geometry.textInset(stateColumn: true))
        view.appearance = NSAppearance(named: appearance)
        precondition(view.frame.height == geometry.rowHeight && view.frame.width > geometry.textInset(stateColumn: true) + 40, "view rows are standard height and fit their text")
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var best: [NSColor] = [], top: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.01 else { continue }
            if pixel.alphaComponent > top + 0.001 { top = pixel.alphaComponent; best = [pixel] } else if abs(pixel.alphaComponent - top) <= 0.001 { best.append(pixel) }
        } }
        precondition(!best.isEmpty, "something was drawn")
        func average(_ part: (NSColor) -> CGFloat) -> Int { Int((best.map(part).reduce(0, +) / CGFloat(best.count) * 255).rounded()) }
        return (average(\.redComponent), average(\.greenComponent), average(\.blueComponent), top)
    }
    func close(_ got: (r: Int, g: Int, b: Int, alpha: CGFloat), _ want: (Int, Int, Int), alpha: CGFloat) -> Bool {
        abs(got.r - want.0) <= 2 && abs(got.g - want.1) <= 2 && abs(got.b - want.2) <= 2 && abs(got.alpha - alpha) <= 0.02
    }
    let claudeTarget = (Int((217 * 0.92).rounded()), Int((119 * 0.92).rounded()), Int((87 * 0.92).rounded()))
    var report: [String] = []
    for (name, dark) in [(NSAppearance.Name.darkAqua, true), (.aqua, false)] {
        let title = sample(NotchQMenuPalette.title, name), codex = sample(NotchQMenuPalette.codex, name), claude = sample(NotchQMenuPalette.claude, name)
        let ink = dark ? (255, 255, 255) : (0, 0, 0), grey = dark ? 204 : 51
        precondition(close(title, ink, alpha: 1), "title is pure \(dark ? "white" : "black") in a \(dark ? "dark" : "light") menu: \(title)")
        precondition(close(codex, (grey, grey, grey), alpha: 1), "Codex is an opaque grey \(grey): \(codex)")
        precondition(close(claude, claudeTarget, alpha: 1), "Claude is the opaque orange × 0.92 \(claudeTarget): \(claude)")
        report.append("\(dark ? "dark" : "light"): title \(title.r),\(title.g),\(title.b) a\(String(format: "%.2f", title.alpha)); Codex \(codex.r),\(codex.g),\(codex.b) a\(String(format: "%.2f", codex.alpha)); Claude \(claude.r),\(claude.g),\(claude.b) a\(String(format: "%.2f", claude.alpha))")
    }
    // Hue and saturation equal the badge's; only brightness is lower.
    let badge = NotchQProvider.claude.color.usingColorSpace(.sRGB)!, menu = NotchQMenuPalette.claude.usingColorSpace(.sRGB)!
    precondition(abs(badge.hueComponent - menu.hueComponent) < 0.003 && abs(badge.saturationComponent - menu.saturationComponent) < 0.003 && abs(menu.brightnessComponent / badge.brightnessComponent - 0.92) < 0.003 && menu.alphaComponent == 1, "Claude: badge hue and saturation, brightness × 0.92, opaque")
    // Retitling a row in place keeps its view (the open menu is not rebuilt).
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    NotchQAppDelegate.notchQSetMenuRow(item, "Weekly: 40% left", provider: .claude); let view = item.view
    NotchQAppDelegate.notchQSetMenuRow(item, "Weekly: 39% left", provider: .claude)
    precondition(item.view === view && (view as? NotchQMenuRowView)?.text == "Weekly: 39% left" && item.title == "Weekly: 39% left", "same view, new text")
    NotchQAppDelegate.notchQSetMenuRow(item, "Last updated: 12:00:00 (0 s ago)", provider: .claude)
    precondition(item.view == nil && item.attributedTitle == nil && item.title.hasPrefix("Last updated"), "a faded row is a plain disabled item again")
    print("Passed menu colour pixel checks: " + report.joined(separator: " | "))
}

/// The open dropdown keeps its time-dependent rows current by retitling the same menu items.
func runNotchQLiveMenuChecks() {
    precondition(notchQDurationText(0) == "0 s" && notchQDurationText(35.9) == "35 s" && notchQDurationText(125) == "2 min 05 s" && notchQDurationText(6840) == "1 h 54 min" && notchQDurationText(442_800) == "5 d 3 h" && notchQDurationText(-4) == "0 s", "compact durations")
    let start = Date(timeIntervalSince1970: 1000)
    var clock = start
    func snapshot(_ five: Int, _ week: Int) -> NotchQUsageSnapshot {
        NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: five, minutes: 300, reset: start.addingTimeInterval(7200)), NotchQUsageWindow(remaining: week, minutes: 10080, reset: start.addingTimeInterval(172_800))])
    }
    let delegate = NotchQAppDelegate()
    delegate.menuClock = { clock }
    delegate.providers = [.codex, .claude]
    delegate.state.notchQRecordSuccess(snapshot(99, 13), now: start); delegate.state.nextAllowed = start.addingTimeInterval(90)
    delegate.claudeState.notchQRecordSuccess(snapshot(50, 40), now: start)
    let menu = NSMenu(); delegate.menuWillOpen(menu)
    precondition(delegate.menuTimer?.isValid == true && delegate.openMenu === menu, "the one-second timer runs while the menu is open")
    let all = menu.items, codex = delegate.liveMenuRows[.codex]!, claude = delegate.liveMenuRows[.claude]!
    func titles(_ provider: NotchQProvider) -> [String] { delegate.liveMenuRows[provider]!.map(\.title) }
    precondition(titles(.codex).count == 6 && titles(.codex)[0] == "5-hour: 99% left" && titles(.codex)[2].hasSuffix("(in 2 h 0 min)") && titles(.codex)[3].hasSuffix("(in 2 d 0 h)") && titles(.codex)[4].hasSuffix("(0 s ago)") && titles(.codex)[5] == "Next check in 90 seconds", "rows as of the moment the menu opens")
    // The clock advances: same items, new text.
    clock = start.addingTimeInterval(35); delegate.notchQTickMenu()
    precondition(titles(.codex)[4].hasPrefix("Last updated: ") && titles(.codex)[4].hasSuffix("(35 s ago)") && titles(.codex)[2].hasSuffix("(in 1 h 59 min)") && titles(.codex)[5] == "Next check in 55 seconds" && titles(.claude)[4].hasSuffix("(35 s ago)"), "age, reset countdown and next check tick for both providers")
    precondition(menu.items.count == all.count && zip(menu.items, all).allSatisfy { $0 === $1 } && zip(delegate.liveMenuRows[.codex]!, codex).allSatisfy { $0 === $1 }, "the menu is not rebuilt; items are retitled in place")
    // A new reading arrives while the menu is open.
    clock = start.addingTimeInterval(40); delegate.state.notchQRecordSuccess(snapshot(42, 13), now: clock); delegate.state.nextAllowed = clock.addingTimeInterval(10)
    delegate.notchQTickMenu()
    precondition(titles(.codex)[0] == "5-hour: 42% left" && titles(.codex)[4].hasSuffix("(0 s ago)") && codex[0] === delegate.liveMenuRows[.codex]![0] && codex[0].title == "5-hour: 42% left", "a new percentage appears in the same row")
    // Weekly nearly used up: the row says it is the one on the badge.
    delegate.claudeState.notchQRecordSuccess(snapshot(50, 3), now: clock); delegate.notchQTickMenu()
    precondition(titles(.claude)[1] == "Weekly: 3% left — nearly used up; shown on the badge" && titles(.claude)[0] == "5-hour: 50% left" && claude[1] === delegate.liveMenuRows[.claude]![1], "both windows stay listed; the weekly row is marked")
    // The number of rows changes: only that row is removed or added, everything else stays.
    let settings = menu.items.first { $0.title == "Settings…" }!, claudeHeader = delegate.liveMenuHeaders[.claude]!
    clock = start.addingTimeInterval(60); delegate.notchQTickMenu()
    precondition(titles(.codex).count == 5 && !menu.items.contains { $0.title.hasPrefix("Next check") } && menu.items.count == all.count - 1, "a row that no longer applies is removed")
    delegate.state.notchQRecordFailure("Offline", now: clock); delegate.notchQTickMenu()
    precondition(delegate.liveMenuRows[.codex]!.allSatisfy { $0.attributedTitle == nil && $0.view == nil }, "an error turns the section's rows back to faded")
    precondition(titles(.codex)[0] == "Offline" && titles(.codex).contains("Last known 5-hour: 42% left") && titles(.codex).contains { $0.hasPrefix("Retry in ") }, "an error and its retry row are added")
    let order = menu.items
    precondition(order.firstIndex { $0 === delegate.liveMenuHeaders[.codex]! }! + titles(.codex).count < order.firstIndex { $0 === claudeHeader }! && order.contains { $0 === settings } && zip(delegate.liveMenuRows[.claude]!, claude).allSatisfy { $0 === $1 }, "added rows stay inside their provider's section")
    delegate.menuDidClose(menu)
    precondition(delegate.menuTimer == nil && delegate.openMenu == nil, "closing the menu stops the timer")
    let frozen = titles(.codex); clock = start.addingTimeInterval(500); delegate.notchQTickMenu()
    precondition(titles(.codex) == frozen, "a closed menu is left alone")
}

/// The blink on a figure whose shown limit is nearly used up: which provider, which rhythm, where, when it
/// runs, Reduce Motion, and that the figure does not move.
func runNotchQPulseChecks() {
    _ = NSApplication.shared
    // The layer on its own.
    let layer = NotchQPulseView()
    layer.notchQApply(shown: false, animate: true, reduceMotion: false)
    precondition(layer.isHidden && !layer.animating && !layer.staticCue && layer.starts == 0 && layer.hitTest(.zero) == nil, "nothing to pulse; clicks pass through")
    layer.notchQApply(shown: true, animate: true, reduceMotion: false)
    let running = layer.layer?.animation(forKey: NotchQPulseView.animationKey) as? CAKeyframeAnimation
    precondition(layer.rhythm == .weekly && !layer.isHidden && layer.animating && layer.starts == 1 && layer.alphaValue == 1 && running?.keyPath == "opacity" && (running?.values as? [Float]) == NotchQPulseRhythm.weekly.opacities && running?.duration == 1.4 && running?.repeatCount == .infinity && running?.timingFunctions?.count == 5, "weekly: a sharp, eased double dip to 0.1 every 1.4 s, repeating")
    let soft = NotchQPulseView(rhythm: .fiveHour); soft.notchQApply(shown: true, animate: true, reduceMotion: false)
    let softLoop = soft.layer?.animation(forKey: NotchQPulseView.animationKey) as? CAKeyframeAnimation
    precondition(soft.animating && (softLoop?.values as? [Float]) == [1, 0.25, 1] && softLoop?.duration == 2.0 && softLoop?.repeatCount == .infinity && softLoop?.timingFunctions?.count == 2, "5-hour: the soft, eased 1.0 to 0.25 and back over 2 s that weekly used before")
    for _ in 0..<5 { layer.notchQApply(shown: true, animate: true, reduceMotion: false) }
    precondition(layer.starts == 1, "refreshing does not restart the loop")
    layer.notchQApply(shown: true, animate: true, reduceMotion: true)
    precondition(!layer.isHidden && !layer.animating && layer.staticCue && layer.alphaValue == NotchQPulseView.staticOpacity && layer.layer?.animation(forKey: NotchQPulseView.animationKey) == nil, "Reduce Motion: no movement, a steady dim instead")
    layer.notchQApply(shown: true, animate: true, reduceMotion: false)
    precondition(layer.animating && layer.starts == 2 && layer.alphaValue == 1, "turning Reduce Motion off resumes the pulse")
    layer.notchQApply(shown: true, animate: false, reduceMotion: false)
    precondition(!layer.isHidden && !layer.animating && layer.layer?.animation(forKey: NotchQPulseView.animationKey) == nil, "a hidden badge or a sleeping Mac stops the loop")
    layer.layer?.removeAnimation(forKey: NotchQPulseView.animationKey); layer.notchQApply(shown: true, animate: true, reduceMotion: false)
    precondition(layer.animating && layer.starts == 3, "restarted after the system dropped it")
    // Title helpers.
    let ranges = notchQProviderRanges([.codex, .claude], codex: "42%", claude: "4%")
    precondition(ranges[.codex] == NSRange(location: 0, length: 3) && ranges[.claude] == NSRange(location: 5, length: 2) && notchQProviderRanges([.claude], codex: "42%", claude: "—%")[.claude] == NSRange(location: 0, length: 2), "where each figure sits")
    let title = notchQProviderTitle([.codex, .claude], codex: "42%", claude: "4%")
    let hidden = notchQMaskedTitle(title, ranges: [ranges[.claude]!], keep: false), kept = notchQMaskedTitle(title, ranges: [ranges[.claude]!], keep: true)
    func color(_ text: NSAttributedString, _ index: Int) -> NSColor? { text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }
    precondition(hidden.string == title.string && kept.string == title.string && color(hidden, 5) == .clear && color(hidden, 0) == color(title, 0) && color(kept, 0) == .clear && color(kept, 5) == color(title, 5), "the two layers split the same title")
    precondition(NotchQBadgeLayout(hidden).size == NotchQBadgeLayout(title).size && NotchQBadgeLayout(kept).ink == NotchQBadgeLayout(title).ink, "making a figure transparent changes no width, height or baseline")

    // The app, in the standard menu-bar placement (works on any Mac) and beside the notch where there is one.
    let defaults = NotchQPreferences.defaults, domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    defer { if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) } else { defaults.removePersistentDomain(forName: domain) } }
    defaults.set(false, forKey: "preferNotchPosition")
    // First a picture with nothing low: a 3% threshold keeps Claude's 4% 5-hour figure from blinking.
    defaults.set(3, forKey: NotchQPreferences.lowLimitThresholdKey)
    let delegate = NotchQAppDelegate()
    var reduce = false
    delegate.reduceMotion = { reduce }
    delegate.testingLifecycle = true
    delegate.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    delegate.notch = NotchQBadgeController(); delegate.notch?.reduceMotion = { reduce }
    defer { NSStatusBar.system.removeStatusItem(delegate.item); delegate.notch?.notchQCloseBadge() }
    delegate.providers = [.codex, .claude]
    func reading(_ five: Int?, _ week: Int?) -> NotchQUsageSnapshot {
        NotchQUsageSnapshot(windows: (five.map { [NotchQUsageWindow(remaining: $0, minutes: 300, reset: nil)] } ?? []) + (week.map { [NotchQUsageWindow(remaining: $0, minutes: 10080, reset: nil)] } ?? []))
    }
    func show(codex: NotchQUsageSnapshot, claude: NotchQUsageSnapshot) { delegate.state.notchQRecordSuccess(codex); delegate.claudeState.notchQRecordSuccess(claude); delegate.notchQRenderBadge() }
    func picture(_ view: NSView) -> NSBitmapImageRep {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    /// The box around everything drawn, and how many pixels differ noticeably between two pictures.
    func ink(_ bitmap: NSBitmapImageRep) -> [Int] {
        var box = [Int.max, Int.max, -1, -1]
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
            box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
        } }
        return box
    }
    func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return Int.max }
        var count = 0
        for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide where abs((a.colorAt(x: x, y: y)?.alphaComponent ?? 0) - (b.colorAt(x: x, y: y)?.alphaComponent ?? 0)) > 0.02 { count += 1 } }
        return count
    }
    let button = delegate.item.button!, pulse = delegate.statusPulse, notch = delegate.notch!
    // Nothing nearly used up; Claude shows "4%" from its 5-hour window.
    show(codex: reading(42, 30), claude: reading(4, 30))
    // Give both badges a real size for the pictures (a test never puts them on screen).
    if button.bounds.width < 10 || button.bounds.height < 10 { button.setFrameSize(NSSize(width: 84, height: 22)) }
    button.wantsLayer = true   // as in the real menu bar, where the item and the pulse layer are both layers
    notch.panel.setContentSize(notch.badgeSize)
    button.layoutSubtreeIfNeeded()
    let plain = picture(button), plainNotch = picture(notch.panel.contentView!)
    precondition(delegate.pulsingProviders.isEmpty && pulse.isHidden && !pulse.animating && notch.pulseView.isHidden && notch.pulseRanges.isEmpty && button.attributedTitle.string == "42%  4%", "no pulse while every limit is above the threshold")
    // Back to the default 10%. Claude's weekly limit is down to 4%: the same "4%" is now the weekly figure, and only it pulses.
    defaults.removeObject(forKey: NotchQPreferences.lowLimitThresholdKey)
    show(codex: reading(42, 30), claude: reading(60, 4))
    precondition(delegate.pulsingProviders == [.claude] && delegate.pulsingLimits == [.claude: .weekly] && delegate.statusPulseRanges == [.weekly: [NSRange(location: 5, length: 2)]] && notch.pulseRanges == [.weekly: [NSRange(location: 5, length: 2)]], "only Claude's figure is marked, with the weekly rhythm, in both placements")
    precondition(!pulse.isHidden && pulse.animating && pulse.superview === button && pulse.starts == 1 && !notch.pulseView.animating, "the menu-bar item is on screen, so its figure pulses; the hidden notch badge does not")
    precondition(button.attributedTitle.string == "42%  4%" && (button.attributedTitle.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor) == .clear && (button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) != .clear, "the item leaves Claude's figure to the pulse layer and still draws Codex itself")
    precondition(button.toolTip?.contains("Claude Weekly 4% remaining (weekly limit nearly used up)") == true && button.toolTip?.contains("Codex 5-hour 42% remaining") == true, "the tooltip says which limit is shown")
    button.layoutSubtreeIfNeeded()
    let pulsed = picture(button), pulsedNotch = picture(notch.panel.contentView!)
    precondition(ink(plainNotch)[2] > 0 && differing(pulsedNotch, plainNotch) == 0, "notch badge: with the figure on the pulse layer the badge is pixel-identical")
    // The menu-bar item's own cell draws both layers. Position and size are identical; glyph edges may differ by
    // half a device pixel of antialiasing between drawing contexts, which is all this allows.
    precondition(ink(plain)[2] > 0 && ink(pulsed) == ink(plain) && differing(pulsed, plain) * 50 <= plain.pixelsWide * plain.pixelsHigh, "menu bar: the pulsing figure occupies exactly the same box (differences: \(differing(pulsed, plain)) px)")
    for _ in 0..<4 { delegate.notchQRenderBadge() }
    precondition(pulse.starts == 1 && pulse.animating, "the 10-second refresh does not restart the pulse")
    // Reduce Motion, and the setting changing while the app runs.
    reduce = true; delegate.notchQAccessibilityChanged()
    precondition(!pulse.animating && pulse.staticCue && !pulse.isHidden && pulse.alphaValue == NotchQPulseView.staticOpacity, "Reduce Motion: the figure is steadily dimmed, not animated")
    reduce = false; delegate.notchQAccessibilityChanged()
    precondition(pulse.animating && !pulse.staticCue && pulse.alphaValue == 1 && pulse.starts == 2, "and it pulses again when Reduce Motion is switched off")
    // Sleep and wake.
    delegate.sleeping = true; delegate.notchQRenderBadge()
    precondition(!pulse.animating && delegate.pulsingProviders.isEmpty, "asleep: nothing animates")
    delegate.sleeping = false; delegate.notchQRenderBadge()
    precondition(pulse.animating && pulse.starts == 3, "awake again: the pulse returns")
    // Codex instead, then both, then neither.
    show(codex: reading(70, 2), claude: reading(60, 40))
    precondition(delegate.pulsingProviders == [.codex] && delegate.statusPulseRanges == [.weekly: [NSRange(location: 0, length: 2)]] && button.attributedTitle.string == "2%  60%" && pulse.animating, "Codex follows the same rule; Claude is left alone")
    show(codex: reading(70, 2), claude: reading(60, 0))
    precondition(delegate.pulsingProviders == [.codex, .claude] && delegate.statusPulseRanges[.weekly]?.count == 2 && delegate.statusPulseRanges[.fiveHour] == nil, "both can be nearly used up at once")
    // The new 5-hour warning: Codex's 5-hour figure at 8% blinks softly while Claude's weekly 4% blinks sharply.
    let softLayer = delegate.statusPulses[.fiveHour]!
    show(codex: reading(8, 40), claude: reading(60, 4))
    precondition(delegate.pulsingLimits == [.codex: .fiveHour, .claude: .weekly] && delegate.statusPulseRanges == [.fiveHour: [NSRange(location: 0, length: 2)], .weekly: [NSRange(location: 4, length: 2)]] && button.attributedTitle.string == "8%  4%", "each figure is marked with its own limit")
    precondition(softLayer.animating && softLayer.rhythm == .fiveHour && pulse.animating && softLayer.superview === button && (button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .clear && (button.attributedTitle.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor) == .clear, "two rhythms at once, each on its own layer; the item draws neither figure itself")
    precondition(button.toolTip?.contains("Codex 5-hour 8% remaining (5-hour limit nearly used up)") == true, "the tooltip names the 5-hour limit")
    show(codex: reading(10, 40), claude: reading(60, 40))
    precondition(delegate.pulsingLimits == [.codex: .fiveHour] && softLayer.animating && !pulse.animating && pulse.isHidden, "exactly 10% left warns; the unused weekly layer stops")
    show(codex: reading(5, 8), claude: reading(60, 40))
    precondition(delegate.pulsingLimits == [.codex: .weekly] && button.attributedTitle.string == "8%  60%" && pulse.animating && !softLayer.animating, "both Codex limits low: the weekly figure and rhythm win")
    delegate.claudeState.notchQRecordFailure("Offline"); delegate.notchQRenderBadge()
    precondition(delegate.pulsingProviders == [.codex] && button.attributedTitle.string == "8%  —%", "no figure, no pulse for that provider")
    show(codex: reading(70, 11), claude: reading(60, 40))
    precondition(delegate.pulsingProviders.isEmpty && pulse.isHidden && !pulse.animating && !softLayer.animating && delegate.statusPulseRanges.isEmpty && (button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) != .clear, "the pulse ends when every limit is above the threshold")
    // Beside the notch (only on a Mac that has one): the badge pulses and the hidden menu-bar item does not.
    defaults.set(true, forKey: "preferNotchPosition")
    show(codex: reading(42, 30), claude: reading(60, 4))
    if notch.currentFrame != nil {
        precondition(notch.pulseView.animating && !notch.pulseView.isHidden && !pulse.animating && !delegate.item.isVisible, "notch placement: the badge's figure pulses")
        let started = notch.pulseView.starts
        delegate.notchQRenderBadge(); delegate.notchQRecoverDisplay()
        precondition(notch.pulseView.animating && notch.pulseView.starts == started, "refresh and display recovery keep the same loop running")
        notch.notchQHideBadge(animated: false)
        precondition(!notch.pulseView.animating, "hiding the badge stops its pulse")
        delegate.notchQRenderBadge()
        precondition(notch.pulseView.animating, "and it returns with the badge")
    } else {
        precondition(!notch.pulseView.animating && pulse.animating, "no notch: the menu-bar item carries the pulse")
    }
    print("Passed pulse checks: 5-hour and weekly rhythms, rule per provider, weekly wins, both placements, no restart on refresh, Reduce Motion, sleep/wake, unchanged pixel positions")
}
