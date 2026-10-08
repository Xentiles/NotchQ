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
    return NSAttributedString(string: percentage, attributes: [.font: notchQPercentageFont() ?? NSFont.systemFont(ofSize: 14), .foregroundColor: color])
}

final class NotchQAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let client = NotchQCodexClient()
    var state = NotchQUsageState()
    var item: NSStatusItem!
    var timer: Timer?
    var sleeping = false
    var loginError: String?
    #if NOTCHQ_TESTING
    var showDiagnostic = CommandLine.arguments.contains("--verify-live")
    #else
    let showDiagnostic = false
    #endif
    var diagnosticCount = 0
    var previousQuery: Date?
    var notch: NotchQBadgeController?
    var testingLifecycle = false
    var preferNotch: Bool { NotchQPreferences.preferNotch }
    var providers: [NotchQProvider] = []
    var testPresence: [NotchQProvider]?
    var claudeState = NotchQUsageState()
    let claudeConnection = NotchQClaudeConnection()
    var settings: NotchQSettingsController?
    var displayedProviders: [NotchQProvider] { NotchQProvider.notchQDisplayed(running: providers, codex: state, claude: claudeState) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !showDiagnostic && !testingLifecycle && NSRunningApplication.runningApplications(withBundleIdentifier: notchQApplicationIdentifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
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
        NotificationCenter.default.addObserver(self, selector: #selector(notchQRepositionBadge), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        client.onDisconnect = { [weak self] in
            guard let self = self, !self.sleeping else { return }
            self.state.notchQRecordFailure(NotchQCodexError.disconnected.description); self.notchQRenderBadge()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(notchQWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQAppPresenceChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(notchQAppPresenceChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        notchQUpdateProviderPresence(); notchQRenderBadge(); notchQRefreshUsage()
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
        let timer = Timer(timeInterval: NotchQPreferences.refreshInterval, repeats: true) { [weak self] _ in self?.notchQRefreshUsage() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func notchQRefreshUsage() {
        notchQUpdateProviderPresence()
        notchQRefreshClaude()
        guard providers.contains(.codex), !sleeping, !client.busy, Date() >= state.nextAllowed else { return }
        let now = Date()
        if showDiagnostic {
            if let previous = previousQuery { print(String(format: "query interval=%.3fs", now.timeIntervalSince(previous))) }
            previousQuery = now
        }
        client.notchQFetchUsage { [weak self] result in
            guard let self = self, !self.sleeping else { return }
            switch result {
            case .success(let snapshot): self.state.notchQRecordSuccess(snapshot)
            case .failure(let error): self.state.notchQRecordFailure(error.description, retryAfter: error.retryAfter)
            }
            self.notchQRenderBadge()
            if self.showDiagnostic {
                self.diagnosticCount += 1
                print("reading \(self.diagnosticCount): \(self.state.percentage); process=\(self.client.processIdentifier ?? -1); error=\(self.state.error ?? "none")")
                fflush(stdout)
            }
        }
    }

    func notchQRenderBadge() {
        let displayed = displayedProviders
        let names = displayed.map { provider in "\(provider.displayName) \(provider == .codex ? state.percentage : claudeState.percentage) remaining" }.joined(separator: "; ")
        item.button?.attributedTitle = notchQProviderTitle(displayed, codex: state.percentage, claude: claudeState.percentage, onBlack: false)
        item.button?.toolTip = names
        item.button?.setAccessibilityLabel("AI usage remaining")
        item.button?.setAccessibilityValue(names)
        notch?.notchQUpdateBadge(title: notchQProviderTitle(displayed, codex: state.percentage, claude: claudeState.percentage), indicatorCount: displayed.count, tooltip: names)
        notchQRepositionBadge()
        let codexText = state.error ?? state.snapshot.map { "\($0.remaining)% remaining; checked every 10 seconds." } ?? "Waiting for Codex usage."
        let claudeText = claudeState.error ?? claudeState.snapshot.map { "\($0.remaining)% remaining; recent Claude Code snapshot." } ?? "No recent Claude Code usage snapshot."
        settings?.notchQRefreshSettings(codexMessage: codexText, claudeMessage: claudeText)
    }

    func notchQRefreshClaude() {
        guard !testingLifecycle else { return }
        if providers.contains(.claude), let reading = claudeConnection.notchQCachedReading() {
            claudeState.notchQRecordSuccess(reading.snapshot, now: reading.observedAt)
        } else {
            claudeState.error = claudeConnection.isConnected ? "No recent usage snapshot. Use Claude Code on a supported plan; stale readings are hidden." : "Connect Claude Code in Settings. Claude Free percentages are unavailable."
        }
        notchQRenderBadge()
    }

    @objc func notchQShowSettings() {
        if settings == nil {
            let controller = NotchQSettingsController(connection: claudeConnection)
            controller.onChange = { [weak self] in self?.client.notchQStopClient(); self?.notchQUpdateProviderPresence(); self?.notchQRefreshUsage() }
            controller.onRefresh = { [weak self] in self?.notchQRefreshUsage() }
            controller.onOpenCodex = { [weak self] in self?.notchQOpenCodex() }
            controller.onOpenClaude = { [weak self] in self?.notchQOpenClaude() }
            controller.onQuit = { NSApp.terminate(nil) }
            settings = controller
        }
        settings?.notchQShowSettings()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notchQShowSettings(); return false
    }

    func notchQUpdateProviderPresence() {
        let next: [NotchQProvider]
        if testingLifecycle { next = testPresence ?? [.codex] }
        else if showDiagnostic { next = [.codex] }
        else {
            let candidates = NotchQPreferences.onlyRunningApps ? NotchQProvider.notchQRunning(in: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))) : NotchQProvider.allCases
            next = candidates.filter { $0 == .codex ? NotchQPreferences.codexEnabled : NotchQPreferences.claudeEnabled }
        }
        guard next != providers else { return }
        let hadCodex = providers.contains(.codex)
        providers = next
        if !providers.contains(.codex) { client.notchQStopClient(); state.error = "Codex is not running." }
        else if !hadCodex { state.error = "Fetching current Codex usage…"; state.nextAllowed = .distantPast }
        notchQRenderBadge()
    }
    @objc func notchQAppPresenceChanged() { notchQUpdateProviderPresence(); notchQRefreshUsage() }

    @objc func notchQRepositionBadge() {
        if sleeping || displayedProviders.isEmpty { notch?.notchQHideBadge(animated: !sleeping && !testingLifecycle); item.isVisible = false; return }
        let placed = preferNotch && (notch?.notchQPositionBadge(show: !testingLifecycle, animated: !testingLifecycle) ?? false)
        if !placed { notch?.notchQHideBadge(animated: false) }
        item.isVisible = !placed
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
        notchQMenuInfo("AI quota meter")
        if providers.contains(.codex) {
        notchQMenuInfo("Codex — white")
        if let error = state.error { notchQMenuInfo(error) }
        if let snapshot = state.snapshot {
            if state.error != nil { notchQMenuInfo("Last known: \(snapshot.remaining)% left") }
            let format = DateFormatter(); format.dateStyle = .medium; format.timeStyle = .short
            for window in snapshot.windows {
                let prefix = state.error == nil ? "" : "Last known "
                notchQMenuInfo("\(prefix)\(window.label): \(window.remaining)% left")
                if let reset = window.reset { notchQMenuInfo("Resets \(format.string(from: reset))") }
            }
        }
        if let updated = state.updated {
            let format = DateFormatter(); format.timeStyle = .medium
            notchQMenuInfo("Last updated: \(format.string(from: updated))")
        }
        if Date() < state.nextAllowed {
            notchQMenuInfo("Retry in \(Int(ceil(state.nextAllowed.timeIntervalSinceNow))) seconds")
        }
        }
        if providers.contains(.claude) {
            if providers.contains(.codex) { menu.addItem(.separator()) }
            notchQMenuInfo("Claude — orange")
            if let snapshot = claudeState.snapshot, claudeState.error == nil {
                for window in snapshot.windows { notchQMenuInfo("\(window.label): \(window.remaining)% left") }
                if let time = claudeState.updated { notchQMenuInfo("Snapshot age: \(Int(max(0, Date().timeIntervalSince(time)))) seconds") }
            } else { notchQMenuInfo(claudeState.error ?? "Claude usage unavailable") }
        }
        if notchQPercentageFont() == nil { notchQMenuInfo("Libron unavailable; using the system font") }
        if let loginError = loginError { notchQMenuInfo(loginError) }
        menu.addItem(.separator())
        _ = notchQMenuAction("Settings…", #selector(notchQShowSettings))
        notchQMenuAction("Refresh now", #selector(notchQRefreshUsage)).isEnabled = providers.contains(.codex) && !client.busy && Date() >= state.nextAllowed && !sleeping
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
    @objc func notchQWillSleep() { sleeping = true; timer?.invalidate(); client.notchQStopClient(); notch?.notchQHideBadge(); state.error = "Mac asleep; waiting for a fresh reading."; notchQRenderBadge() }
    @objc func notchQDidWake() { sleeping = false; notchQRepositionBadge(); notchQRefreshUsage(); notchQStartTimer() }
    @objc func notchQQuit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); client.notchQStopClient(wait: true)
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
            alert.informativeText = "Drag NotchQ into Applications, then open the installed app. This keeps login startup and the Claude connection at a stable location."
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
