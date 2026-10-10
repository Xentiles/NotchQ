import AppKit

func renderNotchQSettingsPreview(_ path: String) {
    _ = NSApplication.shared
    let defaults = NotchQPreferences.defaults
    let domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-ui-preview-" + UUID().uuidString)
    defer {
        if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) }
        else { defaults.removePersistentDomain(forName: domain) }
        try? FileManager.default.removeItem(at: directory)
    }
    let connection = NotchQClaudeConnection(directory: directory, configuration: directory.appendingPathComponent("settings.json"))
    defaults.set(false, forKey: "codexEnabled")
    defaults.set(true, forKey: "claudeEnabled")
    defaults.set(true, forKey: "onlyRunningApps")
    try! connection.notchQConnect(executable: URL(fileURLWithPath: "/Applications/NotchQ.app/Contents/MacOS/NotchQ"))
    let delegate = NotchQAppDelegate(claudeConnection: connection)
    delegate.providers = [.claude]
    delegate.notchQUpdateClaudeState()
    let updater = NotchQUpdater(directory: directory.appendingPathComponent("Updates"))
    let controller = NotchQSettingsController(connection: connection, updater: updater)
    let view = controller.window.contentView!
    let output = URL(fileURLWithPath: path)
    let fixtures: [(String, NSAppearance.Name, String, String)] = [
        ("waiting", .darkAqua, delegate.notchQProviderStatusMessage(.codex), delegate.notchQProviderStatusMessage(.claude)),
        ("light", .aqua, "13% remaining; checked every 10 seconds.", "99% remaining; checked every 2 minutes."),
        ("dark", .darkAqua, "13% remaining; checked every 10 seconds.", "99% remaining; checked every 2 minutes."),
        ("error", .darkAqua, "The desktop app is not running. Open it, or turn off “Show only running desktop apps” for terminal use.", "Claude usage check timed out. Sign in to Claude Code; terminal output may be incompatible. Retrying automatically."),
        ("setup", .aqua, "Codex was not found on this Mac. Install it and sign in, or use Choose CLI…", "Claude Code was not found on this Mac. Install it and sign in, or use Choose CLI…")
    ]
    for (name, appearance, codex, claude) in fixtures {
        if name == "setup" { try! connection.notchQDisconnect() }
        defaults.set(name != "waiting", forKey: "codexEnabled")
        view.appearance = NSAppearance(named: appearance)
        controller.notchQRefreshSettings(codexMessage: codex, claudeMessage: claude)
        view.layoutSubtreeIfNeeded()
        let stack = view.subviews.compactMap { $0 as? NSStackView }.first!
        let lastRow = stack.arrangedSubviews.last!
        let bottom = lastRow.convert(lastRow.bounds, to: view)
        precondition(view.bounds.contains(bottom), "Settings controls fit in \(name)")
        precondition(abs(bottom.minY - 20) < 1, "Window height follows contents without unused bottom padding in \(name)")
        func notchQCheckFrames(_ parent: NSView) {
            for child in parent.subviews where !child.isHidden {
                if child is NSButton || child is NSTextField {
                    precondition(view.bounds.insetBy(dx: -1, dy: -1).contains(child.convert(child.bounds, to: view)), "Control outside settings window: \(name)")
                }
                notchQCheckFrames(child)
            }
        }
        notchQCheckFrames(stack)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { preconditionFailure("No settings bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let file = name == "waiting" ? output : output.deletingPathExtension().appendingPathExtension(name + ".png")
        try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
        print("Native Settings preview rendered: \(name), \(Int(view.bounds.width))×\(Int(view.bounds.height))")
    }
    // Update button: greyed out without an update, accent-blue when one is ready to install.
    let release = NotchQRelease(version: NotchQVersion("9.9.9")!, page: URL(string: "https://github.com/Xentiles/NotchQ/releases")!, archive: URL(string: "https://example.com/a.zip")!, signature: URL(string: "https://example.com/a.zip.sig")!)
    for (name, phase) in [("update-none", NotchQUpdater.Phase.upToDate), ("update-ready", NotchQUpdater.Phase.available(release))] {
        updater.notchQPreview(phase); controller.notchQRefreshSettings()
        let button = notchQFindButton(view, "Update")!
        let ready = name == "update-ready"
        precondition(button.isEnabled == ready && (button.keyEquivalent == "\r") == ready && (notchQFindButton(view, "Done")!.keyEquivalent == "\r") == !ready, "Update is greyed out, or the blue default button when ready: \(name)")
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.deletingPathExtension().appendingPathExtension(name + ".png"))
        print("Native Settings preview rendered: \(name)")
    }
}

func notchQFindButton(_ view: NSView, _ title: String) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for child in view.subviews { if let found = notchQFindButton(child, title) { return found } }
    return nil
}
