import AppKit
import ServiceManagement

final class NotchQSettingsSurface: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        wantsLayer = true
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(srgbRed: 37/255, green: 37/255, blue: 34/255, alpha: 1) : NSColor(srgbRed: 245/255, green: 241/255, blue: 232/255, alpha: 1)).cgColor
    }
}

final class NotchQSettingsController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let connection: NotchQClaudeConnection
    let locator: NotchQExecutableLocator
    var onChange: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenCodex: (() -> Void)?
    var onOpenClaude: (() -> Void)?
    var onQuit: (() -> Void)?
    private let notch = NSButton(checkboxWithTitle: "Place beside the notch", target: nil, action: nil)
    private let running = NSButton(checkboxWithTitle: "Show only running desktop apps", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let codex = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let claude = NSButton(checkboxWithTitle: "Claude", target: nil, action: nil)
    private let codexStatus = NSTextField(wrappingLabelWithString: "Checking Codex…")
    private let claudeStatus = NSTextField(wrappingLabelWithString: "Claude Code connection not configured")
    private let codexPath = NSTextField(wrappingLabelWithString: "")
    private let claudePath = NSTextField(wrappingLabelWithString: "")
    private let claudeHelp = NSTextField(wrappingLabelWithString: "Uses Claude Code’s own Pro or Max sign-in. Free-plan percentages are unavailable. The status-line fallback is optional.")
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let connect = NSButton(title: "Status-line fallback…", target: nil, action: nil)
    private let disconnect = NSButton(title: "Remove fallback", target: nil, action: nil)
    private let codexAutomatic = NSButton(title: "Use automatic", target: nil, action: nil)
    private let claudeAutomatic = NSButton(title: "Use automatic", target: nil, action: nil)
    private let loginItems = NSButton(title: "Login Items…", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    let updater: NotchQUpdater?
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let autoUpdate = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let checkUpdates = NSButton(title: "Check now", target: nil, action: nil)
    private let installUpdate = NSButton(title: "Update", target: nil, action: nil)
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private let releaseNotes = NSButton(title: "What's new", target: nil, action: nil)
    private let stack = NSStackView()
    private let contentWidth: CGFloat = 560
    private let inset: CGFloat = 20

    init(connection: NotchQClaudeConnection, locator: NotchQExecutableLocator = .shared, updater: NotchQUpdater? = nil) {
        self.connection = connection; self.locator = locator; self.updater = updater
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "NotchQ Settings"
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.contentView = NotchQSettingsSurface(frame: NSRect(x: 0, y: 0, width: 560, height: 720))
        window.contentView?.viewDidChangeEffectiveAppearance()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: inset)])
        let heading = NSTextField(labelWithString: "NotchQ")
        heading.font = NSFont(name: "Georgia", size: 28) ?? .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = notchQLabel("AI quota meter")
        let wordmark = NSStackView(views: [heading, subtitle]); wordmark.orientation = .vertical; wordmark.alignment = .leading; wordmark.spacing = 2
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "NotchQ", withExtension: "icns") { icon.image = NSImage(contentsOf: url) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true; icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let header = NSStackView(views: [icon, wordmark]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12
        notchQAdd(header)
        notchQAddDivider()
        let display = notchQGroup()
        notchQAddSection("Display", to: display)
        for button in [notch, running, login] { button.target = self; button.action = #selector(notchQChangePreferences(_:)); display.addArrangedSubview(button) }
        notchQAdd(notchQLabel("Uses the menu bar when no notch is available. Turn off the desktop filter for terminal use."), to: display)
        loginStatus.font = .systemFont(ofSize: 12); loginStatus.textColor = .secondaryLabelColor; notchQAdd(loginStatus, to: display)
        loginItems.target = self; loginItems.action = #selector(notchQLoginSettings); loginItems.bezelStyle = .rounded
        display.addArrangedSubview(loginItems)
        notchQAdd(display)
        notchQAddDivider()
        let sources = notchQGroup()
        notchQAddSection("Usage sources", to: sources)
        notchQAdd(notchQLabel("Remaining account allowance, not session tokens. Detected sources show —% until a reading arrives; the menu explains why."), to: sources)
        notchQAdd(sources)
        let codexGroup = notchQGroup()
        codex.target = self; codex.action = #selector(notchQChangePreferences(_:)); codexGroup.addArrangedSubview(codex)
        codexStatus.font = .systemFont(ofSize: 12); codexStatus.textColor = .secondaryLabelColor; notchQAdd(codexStatus, to: codexGroup)
        codexPath.font = .systemFont(ofSize: 11); codexPath.textColor = .tertiaryLabelColor; notchQAdd(codexPath, to: codexGroup)
        let chooseCodex = notchQButton("Choose CLI…", #selector(notchQChooseCLI(_:))); chooseCodex.tag = 0
        codexAutomatic.target = self; codexAutomatic.action = #selector(notchQUseAutomatic(_:)); codexAutomatic.bezelStyle = .rounded; codexAutomatic.tag = 0
        codexGroup.addArrangedSubview(notchQRow([notchQButton("Open Codex", #selector(notchQOpenCodex)), chooseCodex, codexAutomatic]))
        notchQAdd(codexGroup)
        let claudeGroup = notchQGroup()
        claude.target = self; claude.action = #selector(notchQChangePreferences(_:)); claudeGroup.addArrangedSubview(claude)
        claudeStatus.font = .systemFont(ofSize: 12); claudeStatus.textColor = .secondaryLabelColor; notchQAdd(claudeStatus, to: claudeGroup)
        claudePath.font = .systemFont(ofSize: 11); claudePath.textColor = .tertiaryLabelColor; notchQAdd(claudePath, to: claudeGroup)
        connect.target = self; connect.action = #selector(notchQConnectClaude); connect.bezelStyle = .rounded
        disconnect.target = self; disconnect.action = #selector(notchQDisconnectClaude); disconnect.bezelStyle = .rounded
        let chooseClaude = notchQButton("Choose CLI…", #selector(notchQChooseCLI(_:))); chooseClaude.tag = 1
        claudeAutomatic.target = self; claudeAutomatic.action = #selector(notchQUseAutomatic(_:)); claudeAutomatic.bezelStyle = .rounded; claudeAutomatic.tag = 1
        claudeGroup.addArrangedSubview(notchQRow([notchQButton("Open Claude", #selector(notchQOpenClaude)), chooseClaude, claudeAutomatic, connect, disconnect]))
        claudeHelp.font = .systemFont(ofSize: 12); claudeHelp.textColor = .secondaryLabelColor
        notchQAdd(claudeHelp, to: claudeGroup)
        notchQAdd(claudeGroup)
        notchQAddDivider()
        let updates = notchQGroup()
        notchQAddSection("Updates", to: updates)
        updateStatus.font = .systemFont(ofSize: 12); updateStatus.textColor = .secondaryLabelColor; notchQAdd(updateStatus, to: updates)
        autoUpdate.target = self; autoUpdate.action = #selector(notchQToggleAutoUpdate); updates.addArrangedSubview(autoUpdate)
        for (button, action) in [(checkUpdates, #selector(notchQCheckUpdates)), (installUpdate, #selector(notchQInstallUpdate)), (releaseNotes, #selector(notchQReleaseNotes))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        // Update sits beside Check now: greyed out until an update is ready, then the blue default button.
        updates.addArrangedSubview(notchQRow([checkUpdates, installUpdate, releaseNotes]))
        notchQAdd(updates)
        notchQAddDivider()
        done.target = self; done.action = #selector(notchQDone); done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        refresh.target = self; refresh.action = #selector(notchQRefresh); refresh.bezelStyle = .rounded
        let footer = notchQRow([refresh, notchQButton("About", #selector(notchQAbout)), notchQButton("Quit", #selector(notchQQuit))])
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer); footer.addArrangedSubview(done)
        notchQAdd(footer)
        notchQRefreshSettings()
        window.center()
    }
    private func notchQAdd(_ view: NSView, to group: NSStackView? = nil) {
        let parent = group ?? stack
        parent.addArrangedSubview(view)
        if view is NSTextField || view is NSStackView || view is NSBox { view.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true }
        if let label = view as? NSTextField { label.preferredMaxLayoutWidth = contentWidth - 2 * inset }
    }
    private func notchQLabel(_ title: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: title); label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor; return label
    }
    private func notchQGroup() -> NSStackView {
        let group = NSStackView(); group.orientation = .vertical; group.alignment = .leading; group.spacing = 6; return group
    }
    private func notchQAddSection(_ title: String, to group: NSStackView) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13, weight: .semibold); notchQAdd(label, to: group)
    }
    private func notchQAddDivider() {
        let line = NSBox(); line.boxType = .separator; notchQAdd(line)
    }
    private func notchQButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button
    }
    private func notchQRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons); row.orientation = .horizontal; row.spacing = 8; return row
    }
    private func notchQFitWindow() {
        window.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 2 * inset
        guard height > 0, abs((window.contentView?.bounds.height ?? 0) - height) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: contentWidth, height: height))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func notchQShowSettings() {
        notchQRefreshSettings(); window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
    private func notchQLocationText(_ provider: NotchQProvider) -> String {
        guard let location = locator.notchQLocate(provider) else {
            if let chosen = NotchQPreferences.chosenCLI(provider) { return "Chosen CLI is missing: \((chosen as NSString).abbreviatingWithTildeInPath). Choose it again or use automatic." }
            return "Not found. Install \(provider == .codex ? "Codex" : "Claude Code") and sign in, or choose its CLI."
        }
        let path = (location.url.path as NSString).abbreviatingWithTildeInPath
        return (location.source == .chosen ? "Using chosen CLI: " : "Found automatically: ") + path
    }
    func notchQRefreshSettings(codexMessage: String? = nil, claudeMessage: String? = nil, refreshing: Bool = false, canRefresh: Bool = true) {
        notch.state = NotchQPreferences.preferNotch ? .on : .off
        running.state = NotchQPreferences.onlyRunningApps ? .on : .off
        codex.state = NotchQPreferences.codexEnabled ? .on : .off
        claude.state = NotchQPreferences.claudeEnabled ? .on : .off
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let needsApproval = SMAppService.mainApp.status == .requiresApproval
        loginStatus.stringValue = needsApproval ? "Approve startup in macOS Login Items." : ""
        loginStatus.isHidden = !needsApproval; loginItems.isHidden = !needsApproval
        codexStatus.stringValue = codexMessage ?? "Uses your existing Codex sign-in."
        claudeStatus.stringValue = claudeMessage ?? "Uses your existing Claude Code sign-in."
        codexPath.stringValue = notchQLocationText(.codex); claudePath.stringValue = notchQLocationText(.claude)
        codexAutomatic.isHidden = NotchQPreferences.chosenCLI(.codex) == nil
        claudeAutomatic.isHidden = NotchQPreferences.chosenCLI(.claude) == nil
        disconnect.isEnabled = connection.isConnected; connect.isEnabled = !connection.isConnected
        disconnect.isHidden = !connection.isConnected; connect.isHidden = connection.isConnected
        refresh.title = refreshing ? "Refreshing…" : "Refresh"; refresh.isEnabled = canRefresh
        notchQRefreshUpdates()
    }
    @objc private func notchQChangePreferences(_ sender: NSButton) {
        if sender === login {
            do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { notchQShowError("Could not update login startup. Check macOS Login Items.") }
        } else {
            let key = sender === notch ? "preferNotchPosition" : sender === running ? "onlyRunningApps" : sender === codex ? "codexEnabled" : "claudeEnabled"
            NotchQPreferences.defaults.set(sender.state == .on, forKey: key)
        }
        notchQRefreshSettings(); onChange?()
    }
    @objc private func notchQChooseCLI(_ sender: NSButton) {
        let provider: NotchQProvider = sender.tag == 0 ? .codex : .claude
        let picker = NSOpenPanel(); picker.title = "Choose your installed \(provider == .codex ? "codex" : "claude") executable"
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false; picker.showsHiddenFiles = true
        picker.treatsFilePackagesAsDirectories = true
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { notchQShowError("That file is not an executable command-line tool."); return }
        NotchQPreferences.defaults.set(url.path, forKey: NotchQPreferences.chosenCLIKey(provider))
        locator.notchQInvalidate(); onChange?(); notchQRefreshSettings()
    }
    @objc private func notchQUseAutomatic(_ sender: NSButton) {
        NotchQPreferences.defaults.removeObject(forKey: NotchQPreferences.chosenCLIKey(sender.tag == 0 ? .codex : .claude))
        locator.notchQInvalidate(); onChange?(); notchQRefreshSettings()
    }
    @objc private func notchQConnectClaude() {
        let alert = NSAlert(); alert.messageText = "Add the optional status-line fallback?"
        alert.informativeText = "NotchQ already reads Claude usage with Claude Code’s read-only /usage check and does not need this. The fallback is only used when Claude Code cannot be found or run. It adds a local status-line bridge to your Claude Code user settings and backs up the previous command. It forwards only usage limits to NotchQ and preserves your current status-line output. No AI request or subscription change is made."
        alert.addButton(withTitle: "Add fallback"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try connection.notchQConnect(executable: Bundle.main.executableURL!); notchQRefreshSettings(); onChange?() }
        catch { notchQShowError(error.localizedDescription) }
    }
    @objc private func notchQDisconnectClaude() {
        do { try connection.notchQDisconnect(); notchQRefreshSettings(); onChange?() }
        catch { notchQShowError(error.localizedDescription) }
    }
    @objc private func notchQOpenCodex() { onOpenCodex?() }
    @objc private func notchQOpenClaude() { onOpenClaude?() }
    @objc private func notchQRefresh() { onRefresh?() }
    @objc private func notchQLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func notchQDone() { window.orderOut(nil) }
    @objc private func notchQQuit() { onQuit?() }
    func notchQRefreshUpdates() {
        autoUpdate.state = NotchQPreferences.autoCheckUpdates ? .on : .off
        guard let updater = updater else { installUpdate.isEnabled = false; installUpdate.keyEquivalent = ""; done.keyEquivalent = "\r"; notchQFitWindow(); return }
        let version = updater.current.description
        let checked = updater.lastChecked.map { " (checked \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)))" } ?? ""
        var busy = false
        switch updater.phase {
        case .idle: updateStatus.stringValue = "NotchQ \(version)\(checked)."
        case .checking: updateStatus.stringValue = "Checking for updates…"; busy = true
        case .upToDate: updateStatus.stringValue = "NotchQ \(version) is up to date\(checked)."
        case .available(let release): updateStatus.stringValue = "NotchQ \(release.version) is available. You have \(version)."
        case .downloading(let percent): updateStatus.stringValue = "Downloading the update…" + (percent.map { " \($0)%" } ?? ""); busy = true
        case .installing: updateStatus.stringValue = "Installing. NotchQ will reopen in a moment."; busy = true
        case .manualOnly(_, let message), .failed(let message): updateStatus.stringValue = message
        }
        checkUpdates.isEnabled = !busy
        let ready = updater.available != nil && !busy
        installUpdate.isEnabled = ready
        // The window's default button is the native blue one; hand that role to Update while it's ready.
        installUpdate.keyEquivalent = ready ? "\r" : ""; done.keyEquivalent = ready ? "" : "\r"
        installUpdate.title = { switch updater.phase {
            case .manualOnly: return "Download Update…"
            case .downloading, .installing: return "Updating…"
            default: return "Update" } }()
        installUpdate.toolTip = updater.available.map { release in
            if case .manualOnly = updater.phase { return "Open the \(release.version) download page" }
            return "Install \(release.version) and restart NotchQ" } ?? "No update available"
        releaseNotes.isHidden = updater.available == nil
        notchQFitWindow()
    }
    @objc private func notchQToggleAutoUpdate() {
        NotchQPreferences.defaults.set(autoUpdate.state == .on, forKey: "autoCheckUpdates")
        if autoUpdate.state == .on { updater?.notchQCheckIfDue() }
        notchQRefreshUpdates()
    }
    @objc private func notchQCheckUpdates() { updater?.notchQCheck(userInitiated: true) }
    @objc private func notchQInstallUpdate() {
        guard let updater = updater, let release = updater.available else { return }
        if case .manualOnly = updater.phase { NSWorkspace.shared.open(release.page); return }
        updater.notchQInstall()
    }
    @objc private func notchQReleaseNotes() { if let page = updater?.available?.page { NSWorkspace.shared.open(page) } }
    @objc private func notchQAbout() {
        let alert = NSAlert(); alert.messageText = "NotchQ — AI quota meter"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        // Releases are labelled B(eta)v<version>; the bundle keeps the numeric form macOS requires.
        alert.informativeText = "Version \(version.map { "Bv" + $0 } ?? "Preview")\(build.map { " (build \($0))" } ?? "")\nAI Notch Quota\nCopyright © 2026 Xentiles. All rights reserved.\nLibron is included under its SIL Open Font License.\nThis beta is not Developer ID signed or notarized."
        alert.runModal()
    }
    private func notchQShowError(_ message: String) { let alert = NSAlert(); alert.messageText = "NotchQ"; alert.informativeText = message; alert.runModal() }
}
