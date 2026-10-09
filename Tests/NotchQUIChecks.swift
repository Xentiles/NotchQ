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
    let controller = NotchQSettingsController(connection: connection)
    let view = controller.window.contentView!
    let output = URL(fileURLWithPath: path)
    let fixtures: [(String, NSAppearance.Name, String, String)] = [
        ("waiting", .darkAqua, delegate.notchQProviderStatusMessage(.codex), delegate.notchQProviderStatusMessage(.claude)),
        ("light", .aqua, "13% remaining; checked every 10 seconds.", "99% remaining; checked every minute."),
        ("dark", .darkAqua, "13% remaining; checked every 10 seconds.", "99% remaining; checked every minute."),
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
}
