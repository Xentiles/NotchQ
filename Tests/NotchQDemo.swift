import AppKit

/// `--demo-low-limits` (test build only): a live, on-screen walk-through of the low-limit warnings with fake
/// readings, so the blinks and reminder cards can be seen without real usage being low.
///
/// It uses the real notch badge, menu-bar item, dropdown and reminder cards, with an in-memory reminder ledger.
/// It never polls Codex or Claude, never runs the app's launch path (no updater, no single-instance check, no
/// Claude status-line repair) and writes no preferences: its settings live in the volatile argument domain, and
/// the test app's own bundle ID keeps it apart from the real app's defaults in any case.
///
///   0 s  Codex 5-hour 8% / weekly 60%, Claude 5-hour 70% / weekly 50%: Codex blinks softly, a Codex card drops.
///   8 s  Claude weekly drops to 6%: Claude blinks with the sharp double pulse, a second card stacks below.
///  14 s  The dropdown opens for 7 s.
///  25 s  Codex becomes a plan without a subscription: one monthly window at 8%. It switches to the sharp double
///        pulse and a "Codex monthly limit almost used up" card stacks below.
///   Then it holds. Cards stay until closed with X. Quits after 3 minutes, or from the menu's Quit.
func runNotchQLowLimitDemo() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    precondition(Bundle.main.bundleIdentifier != notchQApplicationIdentifier, "the demo runs only from the test app")
    // Settings for this run only; the argument domain is searched first and is never saved.
    UserDefaults.standard.setVolatileDomain(["preferNotchPosition": true, NotchQPreferences.lowLimitThresholdKey: 10,
                                             "lowLimitReminderCard": true, "lowLimitReminderNotification": false,
                                             "codexEnabled": true, "claudeEnabled": true, "onlyRunningApps": false],
                                            forName: UserDefaults.argumentDomain)

    let delegate = NotchQAppDelegate()
    delegate.testingLifecycle = true                     // no Claude checks, no persistent ledger, no launch-time work
    delegate.client.executableOverride = URL(fileURLWithPath: "/nonexistent/notchq-demo-has-no-codex")
    delegate.testPresence = [.codex, .claude]
    delegate.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    delegate.item.menu = NSMenu(); delegate.item.menu?.delegate = delegate
    delegate.item.button?.setAccessibilityLabel("AI usage remaining (demo)")
    delegate.notch = NotchQBadgeController()
    delegate.notch?.onClick = { [weak delegate] in delegate?.notchQShowBadgeMenu() }
    delegate.notch?.reduceMotion = { [weak delegate] in delegate?.reduceMotion() ?? false }
    delegate.reminderCards = NotchQReminderCardController()
    delegate.reminderCards?.reduceMotion = { [weak delegate] in delegate?.reduceMotion() ?? false }
    NSWorkspace.shared.notificationCenter.addObserver(delegate, selector: #selector(NotchQAppDelegate.notchQAccessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(delegate, selector: #selector(NotchQAppDelegate.notchQRecoverDisplay), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    delegate.notchQUpdateProviderPresence()

    let start = Date()
    let fiveHourReset = start.addingTimeInterval(2 * 3600 + 13 * 60), weeklyReset = start.addingTimeInterval(3 * 86400 + 5 * 3600)
    func reading(_ five: Int, _ week: Int) -> NotchQUsageSnapshot {
        NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: five, minutes: 300, reset: fiveHourReset),
                                      NotchQUsageWindow(remaining: week, minutes: 10080, reset: weeklyReset)])
    }
    func say(_ text: String) { print(String(format: "[demo +%5.1fs] ", Date().timeIntervalSince(start)) + text); fflush(stdout) }
    var step = 0
    func apply() {
        // Step 3 (25 s): Codex as a plan without a subscription, a single monthly window at 8%.
        let codex = step < 2 ? reading(8, 60) : NotchQUsageSnapshot(windows: [NotchQUsageWindow(remaining: 8, minutes: 43200, reset: start.addingTimeInterval(20 * 86400))])
        let claude = step == 0 ? reading(70, 50) : reading(70, 6)
        delegate.state.notchQRecordSuccess(codex); delegate.claudeState.notchQRecordSuccess(claude)
        delegate.notchQRenderBadge()
        // In testing mode the delegate only positions the notch badge; put it on screen as the real app does,
        // then render once more so its pulse starts now that it is visible.
        if NotchQPreferences.preferNotch, let notch = delegate.notch, !notch.panel.isVisible, notch.notchQPositionBadge(show: true, animated: true) {
            delegate.item.isVisible = false
            delegate.notchQRenderBadge()
        }
    }
    func report() {
        let placement = delegate.notch?.currentFrame != nil && NotchQPreferences.preferNotch ? "notch badge" : "menu-bar item"
        let limits = delegate.pulsingLimits.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.joined(separator: ", ")
        let cards = delegate.deliveredReminders.map { "\($0.provider.rawValue) \($0.limit.rawValue) \($0.remaining)%" }.joined(separator: "; ")
        say("shown in \(placement): codex \(delegate.state.percentage), claude \(delegate.claudeState.percentage); blinking: \(limits.isEmpty ? "none" : limits); cards delivered: \(cards.isEmpty ? "none" : cards)")
    }
    say("started at \(ISO8601DateFormatter().string(from: start))")
    apply(); report()
    // Keep the fake readings in place every second (so a Refresh from the menu cannot replace them);
    // the badge keeps its running pulse and the ledger keeps each card to once.
    let ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in apply() }
    Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in step = 1; apply(); say("step 2: Claude weekly drops to 6%"); report() }
    // 14 s: open the dropdown for 7 s so its colours can be seen (and captured) on the real screen.
    Timer.scheduledTimer(withTimeInterval: 14, repeats: false) { _ in
        guard let menu = delegate.item.menu else { return }
        let close = Timer(timeInterval: 7, repeats: false) { _ in menu.cancelTracking(); say("dropdown closed") }
        RunLoop.main.add(close, forMode: .common)
        say("opening the dropdown for 7 s")
        if delegate.notch?.button != nil && delegate.notch?.panel.isVisible == true { delegate.notchQShowBadgeMenu() }
        else { delegate.item.button?.performClick(nil) }
    }
    Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in step = 2; apply(); say("step 3: Codex becomes monthly-only at 8%"); report() }
    Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
        ticker.invalidate(); say("3 minutes up; quitting"); report()
        delegate.reminderCards?.notchQCloseAll(); delegate.notch?.notchQCloseBadge(); NSStatusBar.system.removeStatusItem(delegate.item)
        exit(0)
    }
    withExtendedLifetime(delegate) { application.run() }
}
