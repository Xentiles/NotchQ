import AppKit

/// Once per limit per reset: the ledger on its own, persisted and in memory.
func runNotchQReminderLedgerChecks() {
    let suite = "notchq-reminder-checks-\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!
    defer { store.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(3600)
    var ledger = NotchQReminderLedger(defaults: store)
    precondition(ledger.notchQShouldRemind(.claude, .weekly, reset: reset, now: now), "the first low reading of a period reminds")
    precondition(!ledger.notchQShouldRemind(.claude, .weekly, reset: reset, now: now), "only once per period")
    precondition(!ledger.notchQShouldRemind(.claude, .weekly, reset: reset.addingTimeInterval(90), now: now), "a reset time rounded differently is the same period")
    precondition(ledger.notchQShouldRemind(.claude, .fiveHour, reset: reset, now: now) && ledger.notchQShouldRemind(.codex, .weekly, reset: reset, now: now), "each provider and limit has its own reminder")
    ledger.notchQRecovered(.claude, .weekly)
    precondition(!ledger.notchQShouldRemind(.claude, .weekly, reset: reset, now: now), "rising above the threshold and falling back in the same period does not remind again")
    let next = reset.addingTimeInterval(7 * 86_400)
    precondition(ledger.notchQShouldRemind(.claude, .weekly, reset: next, now: reset.addingTimeInterval(60)), "after the reset, the next period reminds again")
    var reloaded = NotchQReminderLedger(defaults: store)
    precondition(!reloaded.notchQShouldRemind(.claude, .weekly, reset: next, now: now), "remembered across relaunches")
    precondition(reloaded.notchQShouldRemind(.codex, .fiveHour, reset: nil, now: now) && !reloaded.notchQShouldRemind(.codex, .fiveHour, reset: nil, now: now), "without a reset time: once")
    precondition(!reloaded.notchQShouldRemind(.codex, .fiveHour, reset: reset, now: now) && reloaded.reminded["codex.fiveHour"] == reset.timeIntervalSince1970, "a reset time that arrives later belongs to the same reminder")
    reloaded.notchQRecovered(.codex, .fiveHour)
    precondition(!reloaded.notchQShouldRemind(.codex, .fiveHour, reset: reset, now: now), "with a known reset time, recovery does not re-arm")
    var memory = NotchQReminderLedger(defaults: nil)
    precondition(memory.notchQShouldRemind(.codex, .weekly, reset: nil, now: now), "in-memory ledger reminds")
    memory.notchQRecovered(.codex, .weekly)
    precondition(memory.notchQShouldRemind(.codex, .weekly, reset: nil, now: now), "without a reset time, a reading above the threshold re-arms the reminder")
    let later = next.addingTimeInterval(3 * 86_400)
    precondition(reloaded.notchQShouldRemind(.claude, .fiveHour, reset: later.addingTimeInterval(3600), now: later), "a new period")
    precondition(reloaded.reminded["claude.weekly"] == nil && reloaded.reminded["claude.fiveHour"] != nil, "periods that ended over a day ago are forgotten")

    // The reminder's words.
    let zone = TimeZone(identifier: "Etc/UTC")!
    let weekly = NotchQReminder(provider: .claude, limit: .weekly, remaining: 8, reset: now.addingTimeInterval(2 * 86_400 + 3 * 3600))
    precondition(weekly.id == "claude.weekly" && weekly.title == "Claude weekly limit almost used up", "title names provider and limit")
    precondition(weekly.notchQDetail(now: now, timeZone: zone).hasPrefix("8% left · resets ") && weekly.notchQDetail(now: now, timeZone: zone).hasSuffix("(in 2 d 3 h)"), "a reset days away gives its day, time and countdown")
    let five = NotchQReminder(provider: .codex, limit: .fiveHour, remaining: 10, reset: now.addingTimeInterval(2 * 3600 + 600))
    precondition(five.title == "Codex 5-hour limit almost used up" && five.notchQDetail(now: now, timeZone: zone).hasPrefix("10% left · resets at ") && five.notchQDetail(now: now, timeZone: zone).hasSuffix("(in 2 h 10 min)"), "a reset today gives its time and countdown")
    precondition(NotchQReminder(provider: .claude, limit: .fiveHour, remaining: 4, reset: nil, resetDescription: "6pm (Etc/UTC)").notchQDetail(now: now, timeZone: zone) == "4% left · resets 6pm", "the provider's own reset text, in the viewer's zone")
    precondition(NotchQReminder(provider: .claude, limit: .fiveHour, remaining: 4, reset: nil).notchQDetail(now: now, timeZone: zone) == "4% left · reset time unavailable", "no reset time")
    print("Passed reminder ledger checks: once per limit per reset, rounding, relaunch, unknown reset times, pruning, wording")
}

/// Reminders in the app: when they appear, the card that drops from the notch, closing it, and Settings.
func runNotchQReminderAppChecks() {
    _ = NSApplication.shared
    let defaults = NotchQPreferences.defaults, domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    defer { if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) } else { defaults.removePersistentDomain(forName: domain) } }
    defaults.set(false, forKey: "preferNotchPosition")
    defaults.removeObject(forKey: NotchQPreferences.lowLimitThresholdKey)
    defaults.removeObject(forKey: "lowLimitReminderCard"); defaults.removeObject(forKey: "lowLimitReminderNotification")
    NotchQPreferences.notchQPrepareDefaults()
    precondition(NotchQPreferences.lowLimitThreshold == 10 && NotchQPreferences.reminderCardEnabled && !NotchQPreferences.reminderNotificationEnabled, "defaults: 10%, card on, notification off")

    let delegate = NotchQAppDelegate()
    delegate.testingLifecycle = true
    delegate.reduceMotion = { true }
    delegate.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    delegate.notch = NotchQBadgeController()
    let cards = NotchQReminderCardController()
    cards.reduceMotion = { true }   // cards go straight to their resting place, so frames can be checked at once
    delegate.reminderCards = cards
    defer { cards.notchQCloseAll(); NSStatusBar.system.removeStatusItem(delegate.item); delegate.notch?.notchQCloseBadge() }
    delegate.providers = [.codex, .claude]
    let now = Date()
    let fiveReset = now.addingTimeInterval(2 * 3600 + 600), weekReset = now.addingTimeInterval(3 * 86_400)
    func reading(_ five: Int, _ week: Int, fiveReset: Date = fiveReset, weekReset: Date = weekReset) -> NotchQUsageSnapshot {
        NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: five, minutes: 300, reset: fiveReset), NotchQUsageWindow(remaining: week, minutes: 10080, reset: weekReset)])
    }
    func show(codex: NotchQUsageSnapshot, claude: NotchQUsageSnapshot) {
        delegate.state.notchQRecordSuccess(codex); delegate.claudeState.notchQRecordSuccess(claude); delegate.notchQRenderBadge()
    }
    func delivered() -> [String] { delegate.deliveredReminders.map(\.id) }
    func shown() -> [String] { cards.cards.map(\.reminder.id) }

    show(codex: reading(50, 40), claude: reading(60, 40))
    precondition(delivered().isEmpty && shown().isEmpty, "nothing low, no reminder")
    show(codex: reading(10, 40), claude: reading(60, 40))
    precondition(delivered() == ["codex.fiveHour"] && shown() == ["codex.fiveHour"] && cards.cards[0].panel.isVisible, "the 5-hour limit at 10%: a card appears")
    let card = cards.cards[0]
    precondition(card.title.stringValue == "Codex 5-hour limit almost used up" && card.figure.stringValue == "10%" && card.detail.stringValue.hasPrefix("10% left · resets at ") && card.close.target === cards, "the card names the limit, its figure and reset, and has a working X")
    precondition((card.figure.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == NotchQProvider.codex.color, "the figure keeps the provider's colour")
    for _ in 0..<3 { delegate.notchQRenderBadge() }
    show(codex: reading(7, 40), claude: reading(60, 40))
    precondition(delivered() == ["codex.fiveHour"] && shown() == ["codex.fiveHour"] && cards.cards[0].figure.stringValue == "7%" && cards.cards[0].panel === card.panel, "once per reset: later readings only update the card that is up")

    // Both Codex limits low: weekly gets its own reminder and wins the badge.
    show(codex: reading(7, 9), claude: reading(60, 40))
    precondition(delivered() == ["codex.fiveHour", "codex.weekly"] && shown() == ["codex.fiveHour", "codex.weekly"] && delegate.state.percentage == "9%", "the weekly limit is reminded too and shown on the badge")
    let first = cards.cards[0].panel.frame, second = cards.cards[1].panel.frame
    precondition(first.size == NotchQReminderCardController.size && second.maxY <= first.minY - NotchQReminderCardController.gap + 0.5 && first.midX == second.midX, "cards stack downwards, centred alike, without overlapping")
    // Every title fits in full in the real label (no "…"), and stays clear of the X.
    for card in cards.cards { precondition(card.title.frame.maxX <= card.close.frame.minX - 4, "the title ends before the X") }
    let sample = cards.cards[0].title
    for provider in NotchQProvider.allCases { for limit in NotchQLowLimit.allCases {
        let text = NotchQReminder(provider: provider, limit: limit, remaining: 5, reset: nil, resetDescription: nil).title
        sample.stringValue = text
        precondition(sample.fittingSize.width <= sample.frame.width, "\"\(text)\" fits on the card (\(sample.fittingSize.width) of \(sample.frame.width) pt)")
    } }
    if let anchor = NotchQReminderCardController.notchQAnchor() {
        precondition(first.maxY <= anchor.top && abs(first.midX - anchor.midX) <= 1, "the first card hangs just below the notch (or menu bar), centred on it")
    }
    cards.cards[0].close.performClick(nil)
    precondition(shown() == ["codex.weekly"] && cards.cards[0].panel.frame == first && !card.panel.isVisible, "the X closes a card; the next one moves up")
    show(codex: reading(6, 9), claude: reading(60, 40))
    precondition(shown() == ["codex.weekly"] && delivered().count == 2, "a closed reminder does not come back in the same period")

    // Only current readings remind: not an error, not while the Mac sleeps.
    delegate.claudeState.notchQRecordSuccess(reading(60, 3)); delegate.claudeState.notchQRecordFailure("Offline"); delegate.notchQRenderBadge()
    precondition(delivered().count == 2, "a reading behind an error never reminds")
    delegate.sleeping = true; show(codex: reading(6, 9), claude: reading(60, 3))
    precondition(delivered().count == 2, "no reminder while the Mac sleeps")
    delegate.sleeping = false; delegate.notchQRenderBadge()
    precondition(delivered() == ["codex.fiveHour", "codex.weekly", "claude.weekly"] && shown() == ["codex.weekly", "claude.weekly"], "awake with a current reading: Claude's weekly reminder")

    // A new period: Codex's limits reset, its card goes, and the next low reading reminds again.
    let nextFive = fiveReset.addingTimeInterval(5 * 3600), nextWeek = weekReset.addingTimeInterval(7 * 86_400)
    show(codex: reading(80, 100, fiveReset: nextFive, weekReset: nextWeek), claude: reading(60, 3))
    precondition(shown() == ["claude.weekly"], "a limit back above the threshold takes its card down")
    show(codex: reading(9, 100, fiveReset: nextFive, weekReset: nextWeek), claude: reading(60, 3))
    precondition(delivered().last == "codex.fiveHour" && delivered().count == 4 && shown() == ["claude.weekly", "codex.fiveHour"], "the next period reminds again")

    // Codex without a subscription: one monthly window. At 9% it is the long class: its own reminder (once per period,
    // as "codex.weekly"), the monthly title, the badge figure, and the sharp double pulse.
    let monthReset = now.addingTimeInterval(20 * 86_400)
    show(codex: NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: 9, minutes: 43200, reset: monthReset)]), claude: reading(60, 3))
    let monthCard = cards.cards.first { $0.reminder.id == "codex.weekly" }
    precondition(delivered().last == "codex.weekly" && delivered().count == 5 && monthCard?.title.stringValue == "Codex monthly limit almost used up" && delegate.state.percentage == "9%" && delegate.pulsingLimits[.codex] == .weekly, "monthly-only Codex at 9%: reminded as its monthly limit, on the badge, with the long-window class")
    let figureRanges = notchQProviderRanges(delegate.displayedProviders, codex: delegate.state.percentage, claude: delegate.claudeState.percentage)
    precondition(Set((delegate.statusPulseRanges[.weekly] ?? []).map(\.location)) == Set([figureRanges[.codex]!.location, figureRanges[.claude]!.location]) && delegate.statusPulseRanges[.fiveHour] == nil, "Codex's monthly figure (and Claude's weekly 3%) are on the weekly (sharp double) pulse layer")
    precondition(delegate.item.button?.toolTip?.contains("Codex Monthly 9% remaining (monthly limit nearly used up)") == true, "the tooltip names the monthly limit")
    // The 5-hour window disappeared with the plan change: its card closes, the monthly card stays.
    precondition(!shown().contains("codex.fiveHour") && shown().contains("codex.weekly") && shown().contains("claude.weekly"), "a class with no window any more closes its card")
    show(codex: reading(9, 100, fiveReset: nextFive, weekReset: nextWeek), claude: reading(60, 3))
    precondition(delivered().count == 5 && shown().contains("codex.fiveHour") == false, "the 5-hour reminder of this period (known reset) is not given again when the window returns")

    // The card switched off: the reminder is still noted (and would go to a notification), but no card appears.
    defaults.set(false, forKey: "lowLimitReminderCard")
    show(codex: reading(9, 100, fiveReset: nextFive, weekReset: nextWeek), claude: reading(8, 3))
    precondition(delivered().last == "claude.fiveHour" && shown() == ["claude.weekly"], "no card while cards are off")
    defaults.set(true, forKey: "lowLimitReminderCard")

    // A higher threshold in Settings: a weekly 15% is now low.
    defaults.set(20, forKey: NotchQPreferences.lowLimitThresholdKey)
    show(codex: reading(50, 15, fiveReset: nextFive, weekReset: nextWeek), claude: reading(8, 3))
    precondition(delivered().last == "codex.weekly" && shown().contains("codex.weekly") && !shown().contains("codex.fiveHour") && delegate.state.percentage == "15%", "the adjustable threshold drives the badge and the reminders")
    defaults.removeObject(forKey: NotchQPreferences.lowLimitThresholdKey)

    // Settings: the threshold menu and the two switches.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-reminder-settings-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let connection = NotchQClaudeConnection(directory: directory, configuration: directory.appendingPathComponent("settings.json"))
    let settings = NotchQSettingsController(connection: connection)
    var warningChanges = 0, enableRequests = 0
    settings.onWarningsChange = { warningChanges += 1 }; settings.onEnableNotifications = { enableRequests += 1 }
    precondition(settings.threshold.itemTitles == ["5%", "10%", "15%", "20%", "25%"] && settings.threshold.titleOfSelectedItem == "10%", "threshold choices, 10% selected by default")
    precondition(settings.reminderCard.state == .on && settings.reminderNotification.state == .off, "the card is on and the notification off by default")
    settings.threshold.selectItem(withTitle: "20%"); NSApp.sendAction(settings.threshold.action!, to: settings.threshold.target, from: settings.threshold)
    precondition(NotchQPreferences.lowLimitThreshold == 20 && warningChanges == 1, "choosing 20% saves it and updates the badge")
    settings.reminderNotification.performClick(nil)
    precondition(NotchQPreferences.reminderNotificationEnabled && enableRequests == 1 && warningChanges == 2, "switching notifications on saves it and asks macOS for permission")
    settings.reminderNotification.performClick(nil); settings.reminderCard.performClick(nil)
    precondition(!NotchQPreferences.reminderNotificationEnabled && !NotchQPreferences.reminderCardEnabled && enableRequests == 1, "both switches turn off; turning off asks nothing")
    defaults.set(7, forKey: NotchQPreferences.lowLimitThresholdKey); settings.notchQRefreshWarnings()
    precondition(settings.threshold.titleOfSelectedItem == "7%", "a threshold set outside Settings is shown as it is")
    settings.window.close()
    let tipStore = UserDefaults(suiteName: "notchq-tip-checks-\(UUID().uuidString)")!
    tipStore.set(true, forKey: NotchQReminderNotifier.alertsTipKey)
    precondition(!NotchQReminderNotifier.notchQShowAlertsTipIfNeeded(defaults: tipStore) && NotchQReminderNotifier.alertsTipText.contains("Alerts") && NotchQReminderNotifier.notificationSettingsURL.scheme == "x-apple.systempreferences", "the Alerts tip is shown only once and points to Notification settings")
    print("Passed reminder checks: when reminders appear, once per limit per reset, card text, stacking and X, errors and sleep, new periods, switches, threshold and Settings")
}
