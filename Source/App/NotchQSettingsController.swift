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
    var onChange: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenCodex: (() -> Void)?
    var onOpenClaude: (() -> Void)?
    var onQuit: (() -> Void)?
    private let notch = NSButton(checkboxWithTitle: "Place beside the notch", target: nil, action: nil)
    private let running = NSButton(checkboxWithTitle: "Show only running apps", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let codex = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let claude = NSButton(checkboxWithTitle: "Claude", target: nil, action: nil)
    private let codexStatus = NSTextField(wrappingLabelWithString: "Checking Codex…")
    private let claudeStatus = NSTextField(wrappingLabelWithString: "Claude Code connection not configured")
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let connect = NSButton(title: "Connect Claude Code…", target: nil, action: nil)
    private let disconnect = NSButton(title: "Disconnect", target: nil, action: nil)
    private let stack = NSStackView()

    init(connection: NotchQClaudeConnection) {
        self.connection = connection
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 640), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "NotchQ Settings"
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.contentView = NotchQSettingsSurface(frame: NSRect(x: 0, y: 0, width: 630, height: 640))
        window.contentView?.viewDidChangeEffectiveAppearance()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        let heading = NSTextField(labelWithString: "NotchQ")
        heading.font = NSFont(name: "Georgia", size: 28) ?? .systemFont(ofSize: 28, weight: .semibold)
        notchQAdd(heading); notchQAddLabel("AI quota meter", color: .secondaryLabelColor)
        notchQAddSection("Display")
        for button in [notch, running, login] { button.target = self; button.action = #selector(notchQChangePreferences(_:)); notchQAdd(button) }
        notchQAddLabel("Uses the standard menu bar when macOS does not report a usable notch area. Providers without current readings stay hidden.", color: .secondaryLabelColor)
        loginStatus.font = .systemFont(ofSize: 11); loginStatus.textColor = .secondaryLabelColor; notchQAdd(loginStatus)
        notchQAddSection("Usage sources")
        codex.target = self; codex.action = #selector(notchQChangePreferences(_:)); notchQAdd(codex)
        codexStatus.font = .systemFont(ofSize: 12); codexStatus.textColor = .secondaryLabelColor; notchQAdd(codexStatus)
        notchQAddRow([notchQButton("Open Codex", #selector(notchQOpenCodex)), notchQButton("Choose Codex CLI…", #selector(notchQChooseCLI))])
        claude.target = self; claude.action = #selector(notchQChangePreferences(_:)); notchQAdd(claude)
        claudeStatus.font = .systemFont(ofSize: 12); claudeStatus.textColor = .secondaryLabelColor; notchQAdd(claudeStatus)
        connect.target = self; connect.action = #selector(notchQConnectClaude)
        disconnect.target = self; disconnect.action = #selector(notchQDisconnectClaude)
        notchQAddRow([connect, disconnect, notchQButton("Open Claude", #selector(notchQOpenClaude))])
        notchQAddLabel("Claude uses Claude Code’s documented usage snapshots after responses on supported plans. Free-plan percentages are unavailable. NotchQ does not read passwords or run AI prompts.", color: .secondaryLabelColor)
        notchQAddRow([notchQButton("Refresh", #selector(notchQRefresh)), notchQButton("Login Items…", #selector(notchQLoginSettings)), notchQButton("About", #selector(notchQAbout)), notchQButton("Done", #selector(notchQDone)), notchQButton("Quit", #selector(notchQQuit))])
        notchQRefreshSettings()
    }
    private func notchQAdd(_ view: NSView) {
        stack.addArrangedSubview(view)
        if view is NSTextField { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    private func notchQAddLabel(_ title: String, color: NSColor) {
        let label = NSTextField(wrappingLabelWithString: title); label.font = .systemFont(ofSize: 12); label.textColor = color; notchQAdd(label)
    }
    private func notchQAddSection(_ title: String) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13, weight: .semibold); notchQAdd(label)
    }
    private func notchQButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button
    }
    private func notchQAddRow(_ buttons: [NSButton]) {
        let row = NSStackView(views: buttons); row.orientation = .horizontal; row.spacing = 8; notchQAdd(row)
    }
    func notchQShowSettings() { notchQRefreshSettings(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func notchQRefreshSettings(codexMessage: String? = nil, claudeMessage: String? = nil) {
        notch.state = NotchQPreferences.preferNotch ? .on : .off
        running.state = NotchQPreferences.onlyRunningApps ? .on : .off
        codex.state = NotchQPreferences.codexEnabled ? .on : .off
        claude.state = NotchQPreferences.claudeEnabled ? .on : .off
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginStatus.stringValue = SMAppService.mainApp.status == .requiresApproval ? "Approve NotchQ in macOS Login Items to finish enabling startup." : "Usage checks run every 10 seconds while awake."
        codexStatus.stringValue = codexMessage ?? (NotchQCodexClient.notchQResolveExecutable() == nil ? "Install Codex and sign in, or choose your existing Codex CLI." : "Uses your installed Codex sign-in.")
        claudeStatus.stringValue = claudeMessage ?? (connection.isConnected ? "Connected; waiting for a recent Claude Code usage snapshot." : "Optional Claude Code connection is not configured.")
        disconnect.isEnabled = connection.isConnected; connect.isEnabled = !connection.isConnected
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
    @objc private func notchQChooseCLI() {
        let picker = NSOpenPanel(); picker.title = "Choose your installed Codex executable"; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
        NotchQPreferences.defaults.set(url.path, forKey: "codexCLIPath"); onChange?(); notchQRefreshSettings()
    }
    @objc private func notchQConnectClaude() {
        let alert = NSAlert(); alert.messageText = "Connect Claude Code to NotchQ?"
        alert.informativeText = "This adds a local status-line bridge to your Claude Code user settings and backs up the previous command. It forwards only usage limits to NotchQ and preserves your current status-line output. Start or restart Claude Code after connecting. No AI request or subscription change is made."
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
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
    @objc private func notchQAbout() {
        let alert = NSAlert(); alert.messageText = "NotchQ — AI quota meter"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Preview"
        alert.informativeText = "Version \(version)\nAI Notch Quota\nCopyright © 2026 Xentiles. All rights reserved.\nLibron is included under its SIL Open Font License.\nThis preview is not Developer ID signed or notarized."
        alert.runModal()
    }
    private func notchQShowError(_ message: String) { let alert = NSAlert(); alert.messageText = "NotchQ"; alert.informativeText = message; alert.runModal() }
}
