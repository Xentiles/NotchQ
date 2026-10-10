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
    var claudeReadWasPolled = false
    var claudeCadence = NotchQPollCadence(base: NotchQPreferences.claudeRefreshInterval, maximum: 900)
    let claudeConnection: NotchQClaudeConnection
    var settings: NotchQSettingsController?
    var locator = NotchQExecutableLocator.shared
    var runningIdentifiers: () -> Set<String> = { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    // Every enabled, detected source stays visible; a failed or missing reading shows "—%",
    // so the badge and its menu remain reachable to explain the problem.
    var displayedProviders: [NotchQProvider] { providers }

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
        return claudeState.error ?? claudeState.snapshot?.displayWindow.map { claudeReadWasPolled ? "\($0.remaining)% remaining; checked every minute." : "\($0.remaining)% remaining; recent status-line snapshot." } ?? "Waiting for usage."
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
        NotificationCenter.default.addObserver(self, selector: #selector(notchQRecoverDisplay), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        client.onDisconnect = { [weak self] in
            guard let self = self, !self.sleeping else { return }
            self.state.notchQRecordFailure(NotchQSourceError.disconnected.description); self.notchQRenderBadge()
        }
        let center = NSWorkspace.shared.notificationCenter
        // Pause for system sleep, display sleep and fast user switching. Any of the wake signals
        // resumes, so one missed didWake notification cannot leave polling stopped until relaunch.
        center.addObserver(self, selector: #selector(notchQWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
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
        let timer = Timer(timeInterval: NotchQPreferences.refreshInterval, repeats: true) { [weak self] _ in self?.notchQPollUsage() }
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
            NotchQDiagnostics.shared.record(self.state.error == nil ? .succeeded : .failed, provider: .codex, remaining: self.state.snapshot?.displayWindow?.remaining, seconds: Date().timeIntervalSince(now))
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
            if let error = reading.error { return "\(provider.displayName) usage unavailable: \(error)" }
            guard let window = reading.snapshot?.displayWindow else { return "\(provider.displayName) usage unavailable; awaiting a fresh reading" }
            return "\(provider.displayName) \(window.label) \(reading.percentage) remaining"
        }.joined(separator: "; ")
        item.button?.attributedTitle = notchQProviderTitle(displayed, codex: state.percentage, claude: claudeState.percentage, onBlack: false)
        item.button?.toolTip = names
        item.button?.setAccessibilityLabel("AI usage remaining")
        item.button?.setAccessibilityValue(names)
        notch?.notchQUpdateBadge(title: notchQProviderTitle(displayed, codex: state.percentage, claude: claudeState.percentage), indicatorCount: displayed.count, tooltip: names)
        notchQRepositionBadge()
        settings?.notchQRefreshSettings(codexMessage: notchQProviderStatusMessage(.codex), claudeMessage: notchQProviderStatusMessage(.claude), refreshing: !manualRefreshPending.isEmpty || client.busy || claudeClient.busy, canRefresh: !sleeping && !providers.isEmpty && manualRefreshPending.isEmpty)
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
            claudeState.error = "Connection configured; no current quota reading. Install/update Claude Code and sign in with Pro/Max. The status-line fallback needs a response."
        }
    }

    func notchQRefreshClaude() {
        guard !testingLifecycle || claudeClient.executableOverride != nil else { return }
        if notchQProviderInactiveMessage(.claude) != nil || sleeping {
            manualRefreshPending.remove(.claude)
            claudeClient.notchQStop()
            notchQUpdateClaudeState(); notchQRenderBadge(); return
        }
        // The optional status-line snapshot is only used when no local CLI can be resolved.
        guard claudeClient.executableOverride != nil || locator.notchQLocate(.claude) != nil else {
            manualRefreshPending.remove(.claude)
            claudeReadWasPolled = false
            notchQUpdateClaudeState(); notchQRenderBadge(); return
        }
        guard !claudeClient.busy, Date() >= claudeState.nextAllowed else { return }
        manualRefreshPending.remove(.claude)
        let generation = requestGeneration, started = Date()
        NotchQDiagnostics.shared.record(.requestStarted, provider: .claude)
        if claudeState.snapshot == nil { claudeState.error = "Checking usage…"; notchQRenderBadge() }
        claudeClient.notchQFetchUsage { [weak self] result in
            guard let self = self, !self.sleeping, !self.shuttingDown, self.providers.contains(.claude), self.requestGeneration == generation else { return }
            let now = Date()
            switch result {
            case .success(let snapshot):
                self.claudeReadWasPolled = true; self.claudeState.notchQRecordSuccess(snapshot, now: now)
                self.claudeState.nextAllowed = now.addingTimeInterval(self.claudeCadence.notchQSucceeded())
            case .failure(let error) where error.retryAfter != nil:
                let wait = self.claudeCadence.notchQThrottled()
                self.claudeState.notchQRecordFailure("Claude’s usage service is rate limiting checks. Next check in about \(Int(wait / 60)) min.", now: now, retryAfter: wait)
            case .failure(let error):
                self.claudeState.notchQRecordFailure(error.description, now: now)
                self.claudeState.nextAllowed = max(self.claudeState.nextAllowed, now.addingTimeInterval(self.claudeCadence.interval))
            }
            NotchQDiagnostics.shared.record(self.claudeState.error == nil ? .succeeded : .failed, provider: .claude, remaining: self.claudeState.snapshot?.displayWindow?.remaining, seconds: Date().timeIntervalSince(started))
            self.notchQRenderBadge()
            if self.manualRefreshPending.contains(.claude) { self.claudeState.notchQPrepareManualRefresh(); self.notchQPollUsage(only: [.claude]) }
        }
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
            controller.onQuit = { NSApp.terminate(nil) }
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
    func notchQRepositionBadge(recovering: Bool = false) {
        if menuTracking && !sleeping { displayRecoveryPending = true; return }
        if sleeping || displayedProviders.isEmpty { notch?.notchQHideBadge(animated: !sleeping && !testingLifecycle); item.isVisible = false; NotchQDiagnostics.shared.record(.hidden); return }
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
        if providers.contains(.codex) {
            notchQMenuInfo("Codex — white")
            notchQUsageMenuRows(state).forEach(notchQMenuInfo)
        }
        if providers.contains(.claude) {
            if providers.contains(.codex) { menu.addItem(.separator()) }
            notchQMenuInfo("Claude — orange")
            let rows = notchQUsageMenuRows(claudeState)
            (rows.isEmpty ? ["Claude usage unavailable"] : rows).forEach(notchQMenuInfo)
        }
        if notchQPercentageFont() == nil { notchQMenuInfo("Libron unavailable; using the system font") }
        if let loginError = loginError { notchQMenuInfo(loginError) }
        menu.addItem(.separator())
        if let release = updater.available { _ = notchQMenuAction("Update available: \(release.version)…", #selector(notchQShowSettings)) }
        _ = notchQMenuAction("Settings…", #selector(notchQShowSettings))
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
    }

    @objc func notchQOpenCodex() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func notchQOpenLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
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
        menuTracking = false; displayRecoveryPending = false; item.menu?.cancelTracking()
        sleeping = true; recoveryGeneration += 1; requestGeneration += 1; manualRefreshPending.removeAll()
        timer?.invalidate(); client.notchQStopClient(); claudeClient.notchQStop()
        state.error = "Mac asleep; waiting for a fresh reading."; claudeState.error = state.error
        notch?.notchQHideBadge(animated: false); notchQRenderBadge()
        NotchQDiagnostics.shared.record(.sleeping)
    }
    @objc func notchQDidWake() {
        sleeping = false; state.notchQPrepareManualRefresh(); claudeState.notchQPrepareManualRefresh()
        notchQRecoverDisplay(); notchQRefreshUsage(); notchQStartTimer()
    }
    @objc func notchQPause() { if !sleeping { notchQWillSleep() } }
    /// Every wake-like signal lands here; repeated signals for one wake start a single refresh.
    @objc func notchQResume() {
        guard sessionActive, !shuttingDown else { return }
        if !testingLifecycle && !showDiagnostic { updater.notchQCheckIfDue() }
        if sleeping { notchQDidWake() } else { notchQRecoverDisplay() }
    }
    @objc func notchQSessionResigned() { sessionActive = false; notchQPause() }
    @objc func notchQSessionActivated() { sessionActive = true; notchQResume() }
    @objc func notchQQuit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        shuttingDown = true; recoveryGeneration += 1; requestGeneration += 1; manualRefreshPending.removeAll()
        NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate(); client.notchQStopClient(wait: true); claudeClient.notchQStop(wait: true)
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
