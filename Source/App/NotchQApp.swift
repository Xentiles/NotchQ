import AppKit
import ServiceManagement
import CoreText

let notchQApplicationIdentifier = NotchQPreferences.applicationIdentifier
private let bundledFontRegistration: Bool = {
    guard let url = Bundle.main.url(forResource: "Libron-Regular", withExtension: "ttf") else { return false }
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}()

func notchQPercentageFont() -> NSFont? {
    _ = bundledFontRegistration
    return NSFont(name: "Libron-Regular", size: 14) ?? NSFont(name: "Libron", size: 14)
}

func notchQPercentageTitle(_ percentage: String, color: NSColor = .labelColor) -> NSAttributedString {
    let base = notchQPercentageFont() ?? NSFont.systemFont(ofSize: 14)
    // One point size and typographic baseline for every provider and digit combination.
    // Glyph overshoot is part of the typeface; do not shift each percentage separately.
    return NSAttributedString(string: percentage, attributes: [.font: base, .foregroundColor: color])
}

final class NotchQAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let client = NotchQCodexClient()
    let claudeClient = NotchQClaudeUsageClient()
    let updater = NotchQUpdater()
    var state = NotchQUsageState()
    var item: NSStatusItem!
    var timer: Timer?
    var sleeping = false
    var sessionActive = true
    var loginError: String?
    #if NOTCHQ_TESTING
    var showDiagnostic = CommandLine.arguments.contains("--verify-live")
    #else
    let showDiagnostic = false
    #endif
    var diagnosticCount = 0
    var previousQuery: Date?
    var manualRefreshPending: Set<NotchQProvider> = []
    var requestGeneration = 0
    var recoveryGeneration = 0
    var shuttingDown = false
    var menuTracking = false
    var displayRecoveryPending = false
    var notch: NotchQBadgeController?
    var testingLifecycle = false
    var preferNotch: Bool { NotchQPreferences.preferNotch }
    var providers: [NotchQProvider] = []
    var testPresence: [NotchQProvider]?
    var claudeState = NotchQUsageState()
    /// Whether the displayed Claude value came from a /usage check (true) or Claude Code's status line (false).
    var claudeReadWasPolled = false
    /// The latest /usage check's failure, kept while a status-line reading is shown in its place.
    var claudePollFailure: String?
    /// Claude Code's command-line tool is signed out (or billed by API usage); set by those failures, cleared by the next reading.
    var claudeNeedsSignIn = false
    /// Reduce Motion replaces the pulse with a steady dim. Replaced in tests.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The pulse layer over the standard menu-bar item (the notch badge has its own).
    let statusPulse = NotchQPulseView()
    private(set) var statusPulseRanges: [NSRange] = []
    /// Providers whose badge figure is a weekly limit with less than 5% left; their figure pulses.
    var pulsingProviders: [NotchQProvider] {
        sleeping ? [] : displayedProviders.filter { ($0 == .codex ? state : claudeState).pulsing }
    }
    /// The dropdown's time-dependent rows, kept so an open menu can be updated in place every second.
    var menuClock: () -> Date = { Date() }
    private(set) weak var openMenu: NSMenu?
    private(set) var liveMenuHeaders: [NotchQProvider: NSMenuItem] = [:]
    private(set) var liveMenuRows: [NotchQProvider: [NSMenuItem]] = [:]
    private(set) var menuTimer: Timer?
    static let claudeSignedOutMessage = "Claude Code is signed out. Sign in with your Pro or Max account to show usage."
    let claudeSignIn = NotchQClaudeSignIn()
    var claudeCadence = NotchQPollCadence(base: NotchQPreferences.claudeRefreshInterval, maximum: 900)
    let claudeConnection: NotchQClaudeConnection
    var settings: NotchQSettingsController?
    var locator = NotchQExecutableLocator.shared
    var runningIdentifiers: () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    // Every enabled, detected source stays visible; a failed or missing reading shows "—%",
    // so the badge and its menu remain reachable to explain the problem.
    var displayedProviders: [NotchQProvider] { providers }
    /// Nothing to show because no enabled source is installed (or both are switched off): keep a small
    /// neutral menu-bar item so NotchQ stays reachable. Sources hidden only by the running-apps filter stay hidden.
    var showsPlaceholder: Bool {
        guard displayedProviders.isEmpty else { return false }
        let enabled = NotchQProvider.allCases.filter { $0 == .codex ? NotchQPreferences.codexEnabled : NotchQPreferences.claudeEnabled }
        return enabled.allSatisfy { locator.notchQLocate($0) == nil && !($0 == .claude && claudeConnection.isConnected) }
    }

    init(claudeConnection: NotchQClaudeConnection = NotchQClaudeConnection()) {
        self.claudeConnection = claudeConnection
        super.init()
    }

    func notchQProviderInactiveMessage(_ provider: NotchQProvider) -> String? {
        let enabled = provider == .codex ? NotchQPreferences.codexEnabled : NotchQPreferences.claudeEnabled
        if !enabled { return "Source disabled. Enable its checkbox to display remaining allowance." }
        guard !providers.contains(provider) else { return nil }
        if NotchQPreferences.onlyRunningApps {
            return "The desktop app is not running. Open it, or turn off “Show only running desktop apps” for terminal use."
        }
        return "\(provider == .codex ? "Codex" : "Claude Code") was not found on this Mac. Install it and sign in, or use Choose CLI…"
    }

    func notchQProviderStatusMessage(_ provider: NotchQProvider) -> String {
        if let message = notchQProviderInactiveMessage(provider) { return message }
        if provider == .codex {
            return state.error ?? state.snapshot?.displayWindow.map { "\($0.remaining)% remaining; checked every 10 seconds." } ?? "Waiting for usage."
        }
        if claudeSignIn.waiting { return claudeSignIn.message }
        return claudeState.error ?? claudeState.snapshot?.displayWindow.map {
            claudeReadWasPolled ? "\($0.remaining)% remaining; checked every 2 minutes."
                : "\($0.remaining)% remaining; status-line snapshot from Claude Code’s latest reply." + (claudePollFailure.map { " /usage: \($0)" } ?? "")
        } ?? "Waiting for usage."
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !showDiagnostic && !testingLifecycle && NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? notchQApplicationIdentifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "NotchQStatusItem"
        item.isVisible = true
        item.menu = NSMenu(); item.menu?.delegate = self
        item.button?.setAccessibilityLabel("AI usage remaining")
        NotchQPreferences.notchQPrepareDefaults()
        notch = NotchQBadgeController()
        notch?.onClick = { [weak self] in self?.notchQShowBadgeMenu() }
        notch?.reduceMotion = { [weak self] in self?.reduceMotion() ?? false }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(notchQAccessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(notchQRecoverDisplay), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        client.onDisconnect = { [weak self] in
            guard let self = self, !self.sleeping else { return }
            self.state.notchQRecordFailure(NotchQSourceError.disconnected.description); self.notchQRenderBadge()
        }
        let center = NSWorkspace.shared.notificationCenter
        // Pause for system sleep, display sleep and fast user switching. Any of the wake signals
        // resumes, so one missed didWake notification cannot leave polling stopped until relaunch.
        center.addObserver(self, selector: #selector(notchQSystemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQPause), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQSessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQResume), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQResume), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQSessionActivated), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQAppPresenceChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQAppPresenceChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQApplicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQRecoverDisplay), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        claudeClient.onIdle = { [weak self] in
            guard let self = self, self.manualRefreshPending.contains(.claude), !self.sleeping, !self.shuttingDown else { return }
            self.notchQPollUsage(only: [.claude])
        }
        if !testingLifecycle && !showDiagnostic {
            // Only the release app may repoint the user's real Claude status line; never a test build.
            if Bundle.main.bundleIdentifier == notchQApplicationIdentifier {
                _ = try? claudeConnection.notchQRepairExecutablePath(Bundle.main.executableURL!)
            }
            locator.notchQCaptureLoginPath { [weak self] in self?.notchQAppPresenceChanged() }
            let info = Bundle.main.infoDictionary ?? [:], system = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let processor = "arm64"
            #else
            let processor = "x86_64"
            #endif
            NotchQDiagnostics.shared.record(.launched, detail: "Bv\(info["CFBundleShortVersionString"] as? String ?? "?") build=\(info["CFBundleVersion"] as? String ?? "?") macOS=\(system.majorVersion).\(system.minorVersion).\(system.patchVersion) arch=\(processor)")
            updater.onChange = { [weak self] in self?.settings?.notchQRefreshUpdates() }
            updater.notchQStart()
            #if NOTCHQ_TESTING
            // End-to-end check: find, verify and install an update at launch, as if Update were clicked.
            if CommandLine.arguments.contains("--update-now") {
                updater.onChange = { [weak self] in
                    guard let self = self else { return }
                    if case .available = self.updater.phase { self.updater.notchQInstall() }
                    if case .failed(let message) = self.updater.phase { print("update failed: \(message)"); fflush(stdout) }
                }
                updater.notchQCheck(userInitiated: true)
            }
            #endif
        }
        notchQUpdateProviderPresence(); notchQRenderBadge(); notchQPollUsage()
        notchQStartTimer()
        if !testingLifecycle && !showDiagnostic && !NotchQPreferences.defaults.bool(forKey: "didCompleteSetup") {
            NotchQPreferences.defaults.set(true, forKey: "didCompleteSetup")
            notchQShowSettings()
        }
        if showDiagnostic {
            print("font=\(notchQPercentageFont()?.fontName ?? "system fallback")")
            Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in NSApp.terminate(nil) }
        }
    }

    func notchQStartTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: NotchQPreferences.refreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.notchQPollUsage()
            if let hold = self.claudeState.holdUntil, Date() >= hold { self.claudeState.holdUntil = nil; self.notchQRenderBadge() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func notchQRefreshUsage() {
        guard !sleeping, !shuttingDown else { return }
        notchQUpdateProviderPresence()
        // A throttled provider can't be refreshed early; its status says when it retries.
        for provider in providers where (provider == .codex ? state : claudeState).throttledUntil <= Date() {
            manualRefreshPending.insert(provider)
            NotchQDiagnostics.shared.record(.queued, provider: provider)
        }
        state.notchQPrepareManualRefresh(); claudeState.notchQPrepareManualRefresh()
        notchQPollUsage(only: manualRefreshPending)
        notchQRenderBadge()
    }

    func notchQPollUsage(only requested: Set<NotchQProvider>? = nil) {
        guard !sleeping, !shuttingDown else { return }
        notchQUpdateProviderPresence()
        if requested?.contains(.claude) ?? true { notchQRefreshClaude() }
        guard requested?.contains(.codex) ?? true, providers.contains(.codex), !sleeping, !client.busy, Date() >= state.nextAllowed else { return }
        let freshSession = manualRefreshPending.remove(.codex) != nil
        let generation = requestGeneration
        let now = Date()
        NotchQDiagnostics.shared.record(.requestStarted, provider: .codex)
        if showDiagnostic {
            if let previous = previousQuery { print(String(format: "query interval=%.3fs", now.timeIntervalSince(previous))) }
            previousQuery = now
        }
        client.notchQFetchUsage(freshSession: freshSession) { [weak self] result in
            guard let self = self, !self.sleeping, !self.shuttingDown, self.providers.contains(.codex), self.requestGeneration == generation else { return }
            switch result {
            case .success(let snapshot): self.state.notchQRecordSuccess(snapshot)
            case .failure(let error): self.state.notchQRecordFailure(error.description, retryAfter: error.retryAfter)
            }
            NotchQDiagnostics.shared.record(self.state.error == nil ? .succeeded : .failed, provider: .codex, remaining: self.state.snapshot?.displayWindow?.remaining, seconds: Date().timeIntervalSince(now), reason: self.state.error.map(NotchQDiagnostics.notchQReason))
            self.notchQRenderBadge()
            if self.manualRefreshPending.contains(.codex) { self.state.notchQPrepareManualRefresh(); self.notchQPollUsage(only: [.codex]) }
            if self.showDiagnostic {
                self.diagnosticCount += 1
                print("reading \(self.diagnosticCount): \(self.state.percentage); process=\(self.client.processIdentifier ?? -1); error=\(self.state.error ?? "none")")
                fflush(stdout)
            }
        }
    }

    func notchQRenderBadge() {
        let displayed = displayedProviders
        let names = displayed.map { provider in
            let reading = provider == .codex ? state : claudeState
            if reading.holding, let window = reading.snapshot?.displayWindow { return "\(provider.displayName) \(window.label) \(reading.percentage) remaining (last reading; \(reading.error!))" }
            if let error = reading.error { return "\(provider.displayName) usage unavailable: \(error)" }
            guard let window = reading.snapshot?.displayWindow else { return "\(provider.displayName) usage unavailable; awaiting a fresh reading" }
            return "\(provider.displayName) \(window.label) \(reading.percentage) remaining" + (reading.pulsing ? " (weekly limit nearly used up)" : "")
        }.joined(separator: "; ")
        let ranges = notchQProviderRanges(displayed, codex: state.percentage, claude: claudeState.percentage)
        let pulse = pulsingProviders.compactMap { ranges[$0] }
        if showsPlaceholder {
            let image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "NotchQ") ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "NotchQ")
            image?.isTemplate = true
            statusPulseRanges = []
            item.button?.image = image; item.button?.attributedTitle = NSAttributedString(string: image == nil ? "NotchQ" : "")
            item.button?.toolTip = "NotchQ: no Codex or Claude usage source found. Click for details."
            item.button?.setAccessibilityLabel("NotchQ"); item.button?.setAccessibilityValue("No usage source found")
        } else {
            item.button?.image = nil
            // The menu-bar item draws its title itself; a pulsing figure is left out there and drawn by the layer above.
            let title = notchQProviderTitle(displayed, codex: state.percentage, claude: claudeState.percentage, onBlack: false)
            let shown = pulse.isEmpty ? title : notchQMaskedTitle(title, ranges: pulse, keep: false)
            if item.button?.attributedTitle.isEqual(to: shown) != true || pulse != statusPulseRanges { statusPulse.needsDisplay = true }
            statusPulseRanges = pulse
            item.button?.attributedTitle = shown
            if let button = item.button, statusPulse.superview !== button {
                statusPulse.frame = button.bounds; statusPulse.autoresizingMask = [.width, .height]; statusPulse.drawsFlipped = button.isFlipped
                statusPulse.drawContent = { [weak self, weak button] view in
                    guard let self = self, let button = button, let cell = button.cell as? NSButtonCell, !self.statusPulseRanges.isEmpty else { return }
                    // The button's own cell draws the figure, so it lands exactly where the title would put it.
                    let figure = notchQMaskedTitle(notchQProviderTitle(self.displayedProviders, codex: self.state.percentage, claude: self.claudeState.percentage, onBlack: false), ranges: self.statusPulseRanges, keep: true)
                    _ = cell.drawTitle(figure, withFrame: cell.titleRect(forBounds: view.bounds), in: view)
                }
                button.addSubview(statusPulse)
            }
            item.button?.toolTip = names
            item.button?.setAccessibilityLabel("AI usage remaining")
            item.button?.setAccessibilityValue(names)
        }
        notch?.notchQUpdateBadge(title: notchQProviderTitle(displayed, codex: state.percentage, claude: claudeState.percentage), indicatorCount: displayed.count, tooltip: names, pulse: pulse)
        notchQRepositionBadge()
        notchQTickMenu()   // a reading that arrives while the menu is open shows at once
        settings?.notchQRefreshSettings(codexMessage: notchQProviderStatusMessage(.codex), claudeMessage: notchQProviderStatusMessage(.claude), refreshing: !manualRefreshPending.isEmpty || client.busy || claudeClient.busy, canRefresh: !sleeping && !providers.isEmpty && manualRefreshPending.isEmpty,
                                        claudeNeedsSignIn: claudeNeedsSignIn && providers.contains(.claude), signingIn: claudeSignIn.waiting)
    }

    func notchQUpdateClaudeState() {
        if let message = notchQProviderInactiveMessage(.claude) {
            claudeState.error = message
        } else if sleeping {
            claudeState.error = "Mac asleep; waiting for a fresh reading."
        } else if !claudeConnection.isConnected {
            claudeState.error = "Claude Code was not found. Install Claude Code and sign in with Pro/Max, or use Choose CLI…"
        } else if let reading = claudeConnection.notchQCachedReading() {
            claudeState.notchQRecordSuccess(reading.snapshot, now: reading.observedAt)
            NotchQDiagnostics.shared.record(.snapshot, provider: .claude, remaining: reading.snapshot.displayWindow?.remaining)
        } else if claudeConnection.notchQCachedReading(maximumAge: .infinity) != nil {
            claudeState.error = "The last Claude Code reading is older than three minutes and is hidden. Wait for a new Claude Code response."
        } else {
            claudeState.error = "Connection configured; no current quota reading. Install/update Claude Code and sign in with Pro/Max. The status-line bridge needs a Claude Code reply."
        }
    }

    func notchQRefreshClaude() {
        guard !testingLifecycle || claudeClient.executableOverride != nil else { return }
        if notchQProviderInactiveMessage(.claude) != nil || sleeping {
            manualRefreshPending.remove(.claude); claudeSignIn.notchQStop()
            claudeClient.notchQStop()
            notchQUpdateClaudeState(); notchQRenderBadge(); return
        }
        // Without a local CLI the optional status-line snapshot is the only source.
        guard claudeClient.executableOverride != nil || locator.notchQLocate(.claude) != nil else {
            manualRefreshPending.remove(.claude)
            claudeReadWasPolled = false; claudeNeedsSignIn = false; claudeSignIn.notchQStop()
            notchQUpdateClaudeState(); notchQRenderBadge(); return
        }
        // With a CLI, /usage stays the regular check (it also sees claude.ai and Claude Desktop usage);
        // the status line adds the figures Claude Code reported after its latest reply.
        notchQExpireClaudeWindows(); notchQApplyClaudeStatusLine()
        guard !claudeClient.busy, Date() >= claudeState.nextAllowed else { return }
        manualRefreshPending.remove(.claude)
        let generation = requestGeneration, started = Date()
        NotchQDiagnostics.shared.record(.requestStarted, provider: .claude)
        if claudeState.snapshot == nil { claudeState.error = "Checking usage…"; notchQRenderBadge() }
        claudeClient.notchQFetchUsage { [weak self] result in
            guard let self = self, !self.sleeping, !self.shuttingDown, self.providers.contains(.claude), self.requestGeneration == generation else { return }
            let now = Date()
            var failure: String?, reason: NotchQDiagnostics.Reason?
            switch result {
            case .success(let snapshot):
                self.claudeReadWasPolled = true; self.claudePollFailure = nil
                self.claudeNeedsSignIn = false; self.claudeSignIn.notchQStop()
                self.claudeState.notchQRecordSuccess(NotchQUsageSnapshot.notchQMerged(current: self.claudeState.snapshot, incoming: snapshot, now: now) ?? snapshot, now: now)
                self.claudeState.nextAllowed = now.addingTimeInterval(self.claudeCadence.notchQSucceeded())
            case .failure(let error) where error.retryAfter != nil:
                // Claude Code may state when the limit on usage data ends; otherwise back off step by step.
                let wait = error.retryAt.map { min(3600, max(60, $0.timeIntervalSince(now) + 5)) } ?? self.claudeCadence.notchQThrottled()
                let readAt = self.claudeState.updated
                let reading = readAt.map { "Showing the \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)) reading. " } ?? ""
                self.claudeState.notchQRecordFailure("Claude’s usage service is rate limiting checks. \(reading)Next check in about \(max(1, Int((wait / 60).rounded()))) min.", now: now, retryAfter: wait)
                // Keep a recent reading on the badge instead of flickering to "—%" for a short limit.
                if let readAt = readAt, now.timeIntervalSince(readAt) < 300 { self.claudeState.holdUntil = readAt.addingTimeInterval(300) }
                failure = self.claudeState.error
            case .failure(let error):
                // Signed out is a state the user can fix from the menu or Settings; say so plainly.
                self.claudeNeedsSignIn = NotchQClaudeUsageClient.notchQNeedsSignIn(error.description)
                reason = NotchQDiagnostics.notchQReason(for: error.description)
                self.claudeState.notchQRecordFailure(self.claudeNeedsSignIn ? Self.claudeSignedOutMessage : error.description, now: now)
                self.claudeState.nextAllowed = max(self.claudeState.nextAllowed, now.addingTimeInterval(self.claudeCadence.interval))
                failure = self.claudeState.error
            }
            if let failure = failure {
                self.claudePollFailure = failure
                // A status-line reading from the last few minutes stays on the badge; the status text carries the failure.
                if !self.claudeReadWasPolled, self.claudeState.snapshot != nil,
                   let read = self.claudeState.updated, now.timeIntervalSince(read) <= NotchQPreferences.claudeMaximumAge {
                    self.claudeState.error = nil; self.claudeState.holdUntil = nil
                } else { _ = self.notchQApplyClaudeStatusLine(now: now) }
            }
            NotchQDiagnostics.shared.record(failure == nil ? .succeeded : .failed, provider: .claude, remaining: self.claudeState.snapshot?.displayWindow?.remaining, seconds: Date().timeIntervalSince(started), reason: reason ?? failure.map(NotchQDiagnostics.notchQReason))
            self.notchQRenderBadge()
            if self.manualRefreshPending.contains(.claude) { self.claudeState.notchQPrepareManualRefresh(); self.notchQPollUsage(only: [.claude]) }
        }
    }

    /// A displayed Claude window whose reset time has passed is no longer current: stop showing it and
    /// ask /usage right away (an active rate limit still has to run out first).
    func notchQExpireClaudeWindows(now: Date = Date()) {
        // A status-line reading that stood in for a failing /usage check only does so while it is recent.
        if !claudeReadWasPolled, claudeState.error == nil, let failure = claudePollFailure,
           let read = claudeState.updated, now.timeIntervalSince(read) > NotchQPreferences.claudeMaximumAge {
            claudeState.error = failure; notchQRenderBadge()
        }
        guard let snapshot = claudeState.snapshot, snapshot.windows.contains(where: { $0.reset.map { $0 <= now } ?? false }) else { return }
        let headline = snapshot.displayWindow
        claudeState.snapshot = snapshot.notchQUnexpired(now: now)
        if let headline = headline, headline.reset.map({ $0 <= now }) ?? false {
            claudeState.holdUntil = nil
            if claudeState.error == nil { claudeState.error = "The \(headline.label) limit reset. Waiting for a fresh reading." }
        }
        // Ask /usage now, unless it was asked within the last minute: around the reset time Claude Code can
        // still print the old reset, and re-asking every 10 seconds would only earn a rate limit.
        let justPolled = claudeReadWasPolled && (claudeState.updated.map { now.timeIntervalSince($0) < 60 } ?? false)
        if !justPolled { claudeState.nextAllowed = claudeState.throttledUntil }
        notchQRenderBadge()
    }

    /// Applies the status-line bridge's reading when Claude Code reported it after the value now shown.
    /// It never lifts a rate limit or brings the next /usage check forward.
    @discardableResult
    func notchQApplyClaudeStatusLine(now: Date = Date()) -> Bool {
        guard let reading = claudeConnection.notchQCachedReading(now: now),
              reading.observedAt > claudeState.updated ?? .distantPast,
              let merged = NotchQUsageSnapshot.notchQMerged(current: claudeState.snapshot, incoming: reading.snapshot, now: now) else { return false }
        let schedule = (claudeState.nextAllowed, claudeState.throttledUntil, claudeState.failures)
        claudeState.notchQRecordSuccess(merged, now: reading.observedAt)
        (claudeState.nextAllowed, claudeState.throttledUntil, claudeState.failures) = schedule
        claudeReadWasPolled = false
        NotchQDiagnostics.shared.record(.snapshot, provider: .claude, remaining: merged.displayWindow?.remaining)
        notchQRenderBadge()
        return true
    }

    /// Opens Claude Code's own sign-in in Terminal, then waits for `claude auth status` to report a sign-in.
    @objc func notchQSignInClaude() {
        guard claudeNeedsSignIn, !sleeping, !shuttingDown, !claudeSignIn.waiting,
              let executable = claudeClient.executableOverride ?? locator.notchQLocate(.claude)?.url else { return }
        claudeSignIn.notchQStart(executable: executable, changed: { [weak self] in self?.notchQRenderBadge() }) { [weak self] outcome in
            guard let self = self, !self.shuttingDown else { return }
            switch outcome {
            case .signedIn:
                self.claudeNeedsSignIn = false
                self.claudeState.error = "Signed in to Claude Code. Waiting for a fresh reading."
                // Ask /usage right away; a rate limit that is still running has to end first.
                self.claudeState.notchQPrepareManualRefresh()
                self.notchQRenderBadge(); self.notchQPollUsage(only: [.claude])
            case .timedOut:
                self.notchQRenderBadge()
            case .failedToStart:
                self.claudeState.error = "Could not open Terminal for the sign-in. Run claude auth login in Terminal, then refresh."
                self.notchQRenderBadge()
            }
        }
        notchQRenderBadge()
    }

    @objc func notchQShowSettings() {
        if settings == nil {
            let controller = NotchQSettingsController(connection: claudeConnection, updater: updater)
            controller.onChange = { [weak self] in
                guard let self = self else { return }
                self.requestGeneration += 1; self.manualRefreshPending.removeAll()
                self.locator.notchQInvalidate()
                self.client.notchQStopClient(); self.claudeClient.notchQStop()
                // Keep a throttle's explanation; changing settings does not lift the service's limit.
                let now = Date()
                if self.state.throttledUntil <= now { self.state.error = "Waiting for a fresh reading." }
                if self.claudeState.throttledUntil <= now { self.claudeState.error = "Waiting for a fresh reading." }
                self.notchQUpdateProviderPresence(); self.notchQRefreshUsage()
            }
            controller.onRefresh = { [weak self] in self?.notchQRefreshUsage() }
            controller.onOpenCodex = { [weak self] in self?.notchQOpenCodex() }
            controller.onOpenClaude = { [weak self] in self?.notchQOpenClaude() }
            controller.onSignInClaude = { [weak self] in self?.notchQSignInClaude() }
            controller.onQuit = { NSApp.terminate(nil) }
            controller.onReportBug = { [weak self] in self?.notchQReportBug() }
            settings = controller
        }
        settings?.notchQShowSettings()
        notchQRenderBadge()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notchQShowSettings(); return false
    }

    func notchQUpdateProviderPresence() {
        let next: [NotchQProvider]
        if testingLifecycle { next = testPresence ?? [.codex] }
        else if showDiagnostic { next = [.codex] }
        else { next = notchQAvailableProviders() }
        guard next != providers else { return }
        NotchQDiagnostics.shared.record(.detected, detail: "shown=" + (next.isEmpty ? "none" : next.map(\.rawValue).joined(separator: ",")))
        let hadCodex = providers.contains(.codex)
        let hadClaude = providers.contains(.claude)
        providers = next
        if !providers.contains(.codex) { manualRefreshPending.remove(.codex); client.notchQStopClient(); state.error = notchQProviderInactiveMessage(.codex) ?? "Codex is not running." }
        else if !hadCodex { state.error = "Fetching current Codex usage…"; state.notchQPrepareManualRefresh() }
        if !providers.contains(.claude) { manualRefreshPending.remove(.claude); claudeClient.notchQStop(); claudeState.error = notchQProviderInactiveMessage(.claude) ?? "Claude is not running." }
        else if !hadClaude { claudeState.notchQPrepareManualRefresh() }
        notchQRenderBadge()
    }
    /// Enabled sources that are running, or (without the desktop filter) installed on this Mac.
    func notchQAvailableProviders() -> [NotchQProvider] {
        let running = NotchQProvider.notchQRunning(in: runningIdentifiers())
        let candidates = NotchQPreferences.onlyRunningApps ? running : NotchQProvider.allCases.filter { provider in
            running.contains(provider) || locator.notchQLocate(provider) != nil || (provider == .claude && claudeConnection.isConnected)
        }
        return candidates.filter { $0 == .codex ? NotchQPreferences.codexEnabled : NotchQPreferences.claudeEnabled }
    }
    @objc func notchQAppPresenceChanged() {
        locator.notchQInvalidate()
        let previous = providers
        notchQUpdateProviderPresence()
        if previous != providers { notchQPollUsage() }
    }

    @objc func notchQRecoverDisplay() {
        if menuTracking { displayRecoveryPending = true; return }
        recoveryGeneration += 1; let generation = recoveryGeneration
        guard !sleeping, !shuttingDown else { return }
        NotchQDiagnostics.shared.record(.recovering)
        notchQRepositionBadge(recovering: true)
        for delay in [0.25, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.recoveryGeneration == generation, !self.sleeping, !self.shuttingDown else { return }
                self.notchQRepositionBadge(recovering: true)
            }
        }
    }
    /// The menu-bar item's pulse runs only while that item is the one on screen and the Mac is awake.
    func notchQSyncStatusPulse() {
        statusPulse.notchQApply(shown: !statusPulseRanges.isEmpty && !showsPlaceholder, animate: (item?.isVisible ?? false) && !sleeping, reduceMotion: reduceMotion())
    }
    @objc func notchQAccessibilityChanged() { notchQRenderBadge() }

    func notchQRepositionBadge(recovering: Bool = false) {
        // Whichever way this ends, the pulse follows where the badge now is (notch, menu bar, or hidden).
        defer { notchQSyncStatusPulse(); notch?.notchQSyncPulse() }
        if menuTracking && !sleeping { displayRecoveryPending = true; return }
        if sleeping || displayedProviders.isEmpty {
            notch?.notchQHideBadge(animated: !sleeping && !testingLifecycle)
            item.isVisible = !sleeping && showsPlaceholder
            NotchQDiagnostics.shared.record(item.isVisible ? .menuBar : .hidden); return
        }
        let placed = preferNotch && (notch?.notchQPositionBadge(show: !testingLifecycle, animated: !testingLifecycle && !recovering, reassert: recovering) ?? false)
        if !placed { notch?.notchQHideBadge(animated: false) }
        item.isVisible = !placed
        NotchQDiagnostics.shared.record(placed ? .notch : .menuBar, visible: notch?.panel.isVisible, onActiveSpace: notch?.panel.isOnActiveSpace)
    }
    @objc func notchQApplicationActivated(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard application?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        notchQRecoverDisplay()
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === openMenu { notchQStopMenuTimer() }
        guard menu === item?.menu else { return }
        menuTracking = false
        let recover = displayRecoveryPending; displayRecoveryPending = false
        notchQRepositionBadge(recovering: recover)
        if recover { notchQRecoverDisplay() }
    }
    func notchQShowBadgeMenu() {
        guard let menu = item.menu, let button = notch?.button else { return }
        menuWillOpen(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: button)
    }
    @objc func notchQToggleNotchPosition() {
        UserDefaults.standard.set(!preferNotch, forKey: "preferNotchPosition")
        notchQRepositionBadge()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        func notchQMenuInfo(_ title: String) { let row = NSMenuItem(title: title, action: nil, keyEquivalent: ""); row.isEnabled = false; menu.addItem(row) }
        func notchQMenuAction(_ title: String, _ selector: Selector) -> NSMenuItem {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: ""); row.target = self; menu.addItem(row); return row
        }
        notchQMenuInfo("NotchQ")
        menu.addItem(.separator())
        liveMenuHeaders.removeAll(); liveMenuRows.removeAll()
        // Each provider's rows are remembered so notchQTickMenu can retitle them while the menu is open.
        func notchQMenuLive(_ provider: NotchQProvider, _ header: String) {
            notchQMenuInfo(header); liveMenuHeaders[provider] = menu.items.last
            liveMenuRows[provider] = notchQLiveMenuRows(provider).map { notchQMenuInfo($0); return menu.items.last! }
        }
        if providers.contains(.codex) { notchQMenuLive(.codex, "Codex — white") }
        if providers.contains(.claude) {
            if providers.contains(.codex) { menu.addItem(.separator()) }
            notchQMenuLive(.claude, "Claude — orange")
            if claudeNeedsSignIn {
                if claudeSignIn.waiting { notchQMenuInfo(claudeSignIn.message) }
                notchQMenuAction("Sign in to Claude Code…", #selector(notchQSignInClaude)).isEnabled = !sleeping && !claudeSignIn.waiting
            }
        }
        if providers.isEmpty {
            notchQMenuInfo("No usage source to show")
            let enabled = NotchQProvider.allCases.filter { $0 == .codex ? NotchQPreferences.codexEnabled : NotchQPreferences.claudeEnabled }
            if enabled.isEmpty { notchQMenuInfo("Codex and Claude are both switched off in Settings.") }
            enabled.forEach { notchQMenuInfo(notchQProviderStatusMessage($0)) }
        }
        if notchQPercentageFont() == nil { notchQMenuInfo("Libron unavailable; using the system font") }
        if let loginError = loginError { notchQMenuInfo(loginError) }
        menu.addItem(.separator())
        if let release = updater.available { _ = notchQMenuAction("Update available: \(release.version)…", #selector(notchQShowSettings)) }
        _ = notchQMenuAction("Settings…", #selector(notchQShowSettings))
        _ = notchQMenuAction("Report a Bug…", #selector(notchQReportBug))
        notchQMenuAction(manualRefreshPending.isEmpty ? "Refresh now" : "Refresh queued…", #selector(notchQRefreshUsage)).isEnabled = !sleeping && !providers.isEmpty && manualRefreshPending.isEmpty
        if providers.contains(.codex) { _ = notchQMenuAction("Open Codex", #selector(notchQOpenCodex)) }
        if providers.contains(.claude) { _ = notchQMenuAction("Open Claude", #selector(notchQOpenClaude)) }
        let placement = notchQMenuAction("Use notch position", #selector(notchQToggleNotchPosition))
        placement.state = preferNotch ? .on : .off
        if preferNotch && notch?.currentFrame == nil { notchQMenuInfo("No notch detected; using the standard menu bar") }
        let login = notchQMenuAction("Start at login", #selector(notchQToggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval {
            notchQMenuInfo("Login startup needs approval in System Settings")
            _ = notchQMenuAction("Open Login Items settings", #selector(notchQOpenLoginSettings))
        }
        menu.addItem(.separator()); _ = notchQMenuAction("Quit", #selector(notchQQuit))
        if menu === item?.menu { menuTracking = true }
        openMenu = menu; notchQStartMenuTimer()
    }

    /// The text rows under a provider's heading, as of the menu clock.
    func notchQLiveMenuRows(_ provider: NotchQProvider) -> [String] {
        let now = menuClock()
        if provider == .codex { return notchQUsageMenuRows(state, now: now) }
        var rows = notchQUsageMenuRows(claudeState, now: now)
        if rows.isEmpty { rows = ["Claude usage unavailable"] }
        if claudeState.error == nil, claudeState.snapshot != nil {
            rows.append(claudeReadWasPolled ? "Source: Claude Code /usage check" : "Source: Claude Code status line")
            if !claudeReadWasPolled, let failure = claudePollFailure { rows.append("/usage: \(failure)") }
        }
        return rows
    }
    /// Brings the open menu's rows up to date without rebuilding it (a rebuild would close or flicker it):
    /// existing items are retitled; a row is added or removed only when a new reading changes how many there are.
    func notchQTickMenu() {
        guard let menu = openMenu else { return }
        for (provider, header) in liveMenuHeaders {
            let start = menu.index(of: header)
            guard start >= 0 else { continue }
            let rows = notchQLiveMenuRows(provider)
            var items = liveMenuRows[provider] ?? []
            for (index, row) in rows.enumerated() {
                if index < items.count { if items[index].title != row { items[index].title = row } }
                else {
                    let item = NSMenuItem(title: row, action: nil, keyEquivalent: ""); item.isEnabled = false
                    menu.insertItem(item, at: start + 1 + index); items.append(item)
                }
            }
            while items.count > rows.count { menu.removeItem(items.removeLast()) }
            liveMenuRows[provider] = items
        }
    }
    /// Once a second while the menu is open; common modes, so it also fires while the menu tracks the mouse.
    func notchQStartMenuTimer() {
        menuTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.notchQTickMenu() }
        timer.tolerance = 0.1
        menuTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func notchQStopMenuTimer() { menuTimer?.invalidate(); menuTimer = nil; openMenu = nil }

    @objc func notchQOpenCodex() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func notchQOpenLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    /// Copies NotchQ's log (fixed codes only) to the clipboard, then opens the prefilled GitHub bug form.
    @objc func notchQReportBug() {
        DispatchQueue.global(qos: .userInitiated).async {
            let log = NotchQBugReport.notchQCollectLog()
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log, forType: .string)
                if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
                let alert = NSAlert(); alert.messageText = "Report a bug"
                alert.informativeText = "Your browser will open GitHub's bug form with your NotchQ version, macOS version, processor and recent log already filled in. Describe what happened and submit. If the log field says it was shortened, the full log is on your clipboard: select the field's text and paste (⌘V).\n\nThe log has no file paths, tokens or account details. Filing an issue needs a GitHub account."
                alert.addButton(withTitle: "Open Bug Form"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(NotchQBugReport.notchQFormURL(log: log)) }
            }
        }
    }
    @objc func notchQOpenClaude() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: NotchQProvider.claude.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    @objc func notchQToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginError = nil
        } catch { loginError = "Could not change login startup; check System Settings." }
    }
    @objc func notchQWillSleep() {
        menuTracking = false; displayRecoveryPending = false; item.menu?.cancelTracking(); notchQStopMenuTimer()
        sleeping = true; recoveryGeneration += 1; requestGeneration += 1; manualRefreshPending.removeAll()
        state.holdUntil = nil; claudeState.holdUntil = nil
        timer?.invalidate(); client.notchQStopClient(); claudeClient.notchQStop(); claudeSignIn.notchQStop()
        state.error = "Mac asleep; waiting for a fresh reading."; claudeState.error = state.error
        notch?.notchQHideBadge(animated: false); notchQRenderBadge()
    }
    @objc func notchQDidWake() {
        sleeping = false; state.notchQPrepareManualRefresh(); claudeState.notchQPrepareManualRefresh()
        notchQRecoverDisplay(); notchQRefreshUsage(); notchQStartTimer()
    }
    @objc func notchQSystemWillSleep() { notchQWillSleep(); NotchQDiagnostics.shared.record(.sleeping, reason: .systemSleep) }
    @objc func notchQPause() {
        guard !sleeping else { return }
        notchQWillSleep(); NotchQDiagnostics.shared.record(.paused, reason: sessionActive ? .displaySleep : .otherUser)
    }
    /// Every wake-like signal lands here; repeated signals for one wake start a single refresh.
    @objc func notchQResume() {
        guard sessionActive, !shuttingDown else { return }
        if !testingLifecycle && !showDiagnostic { updater.notchQCheckIfDue() }
        if sleeping { NotchQDiagnostics.shared.record(.resumed, reason: .wake); notchQDidWake() } else { notchQRecoverDisplay() }
    }
    @objc func notchQSessionResigned() { sessionActive = false; notchQPause() }
    @objc func notchQSessionActivated() { sessionActive = true; notchQResume() }
    @objc func notchQQuit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        shuttingDown = true; recoveryGeneration += 1; requestGeneration += 1; manualRefreshPending.removeAll(); notchQStopMenuTimer()
        NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate(); client.notchQStopClient(wait: true); claudeClient.notchQStop(wait: true); claudeSignIn.notchQStop()
        notch?.notchQCloseBadge()
        settings?.window.close()
        if showDiagnostic { print("shutdown complete; readings=\(diagnosticCount)") }
    }
}

@main
struct NotchQApp {
    static func main() {
        NotchQPreferences.notchQPrepareDefaults()
        if CommandLine.arguments.contains("--claude-statusline") { exit(NotchQClaudeConnection.notchQStatusLineMain()) }
        if let index = CommandLine.arguments.firstIndex(of: "--install-update") {
            exit(NotchQUpdater.notchQInstallMain(Array(CommandLine.arguments.dropFirst(index + 1))))
        }
        if CommandLine.arguments.contains("--enable-login-item") {
            do { try SMAppService.mainApp.register(); print("login status=\(SMAppService.mainApp.status.rawValue)"); exit(0) }
            catch { print("Login registration failed: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--disable-login-item") {
            do { try SMAppService.mainApp.unregister(); print("login startup disabled"); exit(0) }
            catch { print("Login removal failed: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--login-status") {
            print("login status=\(SMAppService.mainApp.status.rawValue)"); exit(0)
        }
        #if NOTCHQ_TESTING
        if let index = CommandLine.arguments.firstIndex(of: "--font-controls"), CommandLine.arguments.count > index + 1 {
            renderNotchQFontControls(URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--font-audit"), CommandLine.arguments.count > index + 1 {
            runNotchQFontAudit(URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--claude-poll-test"), CommandLine.arguments.count > index + 1 { runNotchQClaudePollingChecks(URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
        if CommandLine.arguments.contains("--detection-report") { runNotchQDetectionReport(); exit(0) }
        if CommandLine.arguments.contains("--claude-usage-live-check") { runNotchQClaudeUsageLiveCheck(); exit(0) }
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings-preview"), CommandLine.arguments.count > index + 1 { renderNotchQSettingsPreview(CommandLine.arguments[index + 1]); exit(0) }
        if CommandLine.arguments.contains("--self-test") {
            runNotchQChecks(); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--transport-test"), CommandLine.arguments.count > index + 1 {
            runNotchQTransportChecks(URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--lifecycle-test"), CommandLine.arguments.count > index + 1 {
            runNotchQLifecycleChecks(URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            renderNotchQFontPreview(CommandLine.arguments[index + 1]); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-notch-preview"), CommandLine.arguments.count > index + 1 {
            renderNotchQNotchPreview(CommandLine.arguments[index + 1]); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-provider-preview"), CommandLine.arguments.count > index + 1 {
            renderNotchQProviderPreview(CommandLine.arguments[index + 1]); exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-padding-preview"), CommandLine.arguments.count > index + 1 {
            renderNotchQPaddingPreview(CommandLine.arguments[index + 1]); exit(0)
        }
        #endif
        let application = NSApplication.shared
        if Bundle.main.bundleURL.path.hasPrefix("/Volumes/") || Bundle.main.bundleURL.path.contains("/AppTranslocation/") {
            let alert = NSAlert(); alert.messageText = "Install NotchQ first"
            alert.informativeText = "Drag NotchQ into Applications, then open it from there. This keeps login startup working at a stable location.\n\nIf macOS says it cannot verify NotchQ, open System Settings → Privacy & Security and click Open Anyway. This beta is not yet notarized by Apple."
            alert.addButton(withTitle: "Open Applications"); alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
            exit(0)
        }
        application.setActivationPolicy(.accessory)
        let delegate = NotchQAppDelegate()
        application.delegate = delegate
        // NSApplication holds its delegate weakly; keep it alive throughout the event loop.
        withExtendedLifetime(delegate) { application.run() }
    }
}
