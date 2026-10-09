import AppKit

func runNotchQDetectionChecks() {
    let files = FileManager.default
    let home = files.temporaryDirectory.appendingPathComponent("notchq-detection-" + UUID().uuidString)
    defer { try? files.removeItem(at: home) }
    func notchQTool(_ relative: String, script: String = "#!/usr/bin/env node\n") -> String {
        let url = home.appendingPathComponent(relative)
        try! files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! script.write(to: url, atomically: true, encoding: .utf8)
        try! files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
    var chosen: [NotchQProvider: String] = [:]
    let locator = NotchQExecutableLocator(home: home, systemDirectories: [], applicationDirectories: [], applicationURL: { _ in nil }, chosenPath: { chosen[$0] })
    precondition(locator.notchQLocate(.codex) == nil && locator.notchQLocate(.claude) == nil, "nothing installed resolves to nothing")

    // npm-through-nvm installs: newest Node version wins (numeric, not lexical, ordering).
    _ = notchQTool(".nvm/versions/node/v9.11.2/bin/codex")
    let newest = notchQTool(".nvm/versions/node/v22.3.0/bin/codex")
    precondition(locator.notchQLocate(.codex) == nil, "results are cached until invalidated")
    locator.notchQInvalidate()
    precondition(locator.notchQLocate(.codex) == NotchQExecutableLocation(url: URL(fileURLWithPath: newest), source: .automatic), "nvm script CLI resolves")
    precondition(locator.notchQLocate(.codex, now: Date().addingTimeInterval(61))?.url.path == newest, "cache expires and re-resolves")

    // A login-shell PATH entry is searched; ~/.local/bin is preferred over it.
    let custom = notchQTool("custom/tools/claude")
    locator.loginPath = [home.appendingPathComponent("custom/tools").path]
    precondition(locator.notchQLocate(.claude)?.url.path == custom, "login-shell PATH finds a custom install")
    let local = notchQTool(".local/bin/claude")
    locator.notchQInvalidate()
    precondition(locator.notchQLocate(.claude)?.url.path == local, "standard install location preferred")

    // Claude Desktop's bundled copy is the last resort.
    let desktopLocator = NotchQExecutableLocator(home: home.appendingPathComponent("desktop-only"), systemDirectories: [], applicationDirectories: [], applicationURL: { _ in nil }, chosenPath: { _ in nil })
    let bundled = home.appendingPathComponent("desktop-only/Library/Application Support/Claude/claude-code/2.1.9/claude.app/Contents/MacOS/claude")
    try! files.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "#!/bin/sh\n".write(to: bundled, atomically: true, encoding: .utf8)
    try! files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
    precondition(desktopLocator.notchQLocate(.claude)?.url.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path, "Claude Desktop's bundled CLI is found")

    // A chosen CLI wins; a missing chosen CLI falls back to automatic detection.
    let manual = notchQTool("elsewhere/codex-wrapper", script: "#!/bin/sh\n")
    chosen[.codex] = manual; locator.notchQInvalidate()
    precondition(locator.notchQLocate(.codex) == NotchQExecutableLocation(url: URL(fileURLWithPath: manual), source: .chosen), "chosen CLI wins")
    chosen[.codex] = home.appendingPathComponent("removed/codex").path; locator.notchQInvalidate()
    precondition(locator.notchQLocate(.codex)?.source == .automatic, "missing chosen CLI falls back to automatic")

    // Children get the CLI's own folder (where nvm keeps `node`) and the login PATH first.
    let environment = locator.notchQChildEnvironment(for: URL(fileURLWithPath: newest), base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path])
    let path = environment["PATH"]!.split(separator: ":").map(String.init)
    precondition(path.first == URL(fileURLWithPath: newest).deletingLastPathComponent().path && path[1] == locator.loginPath[0], "CLI folder and login PATH lead the child PATH")
    precondition(path.contains("/opt/homebrew/bin") && path.contains("/usr/local/bin") && path.filter { $0 == "/usr/bin" }.count == 1 && environment["HOME"] == home.path, "Homebrew added, duplicates removed, other variables kept")

    // Login-shell output may include greeting noise from shell start-up files.
    let noisy = "Welcome!\n\(NotchQExecutableLocator.loginPathBegin)\n/opt/homebrew/bin:/Users/x/.nvm/versions/node/v22/bin:relative\n\(NotchQExecutableLocator.loginPathEnd)\nbye"
    precondition(NotchQExecutableLocator.notchQParseLoginPath(noisy) == ["/opt/homebrew/bin", "/Users/x/.nvm/versions/node/v22/bin"], "login PATH parsed between markers, relative entries dropped")
    precondition(NotchQExecutableLocator.notchQParseLoginPath("no markers") == nil && NotchQExecutableLocator.notchQParseLoginPath("\(NotchQExecutableLocator.loginPathBegin)\n\(NotchQExecutableLocator.loginPathEnd)") == nil, "missing or empty PATH rejected")

    runNotchQPresenceChecks(locator: locator, home: home)
    runNotchQBridgeRepairChecks(home)
    print("Passed detection checks: nvm/login-PATH/Desktop CLIs, chosen CLI fallback, child PATH, installed-source presence, bridge self-heal")
}

private func runNotchQPresenceChecks(locator: NotchQExecutableLocator, home: URL) {
    let defaults = NotchQPreferences.defaults, domain = Bundle.main.bundleIdentifier!
    let saved = defaults.persistentDomain(forName: domain)
    defer { if let saved = saved { defaults.setPersistentDomain(saved, forName: domain) } else { defaults.removePersistentDomain(forName: domain) } }
    defaults.removePersistentDomain(forName: domain)
    defaults.set(true, forKey: "didMigrateLegacyPreferences")
    NotchQPreferences.notchQPrepareDefaults()
    precondition(NotchQPreferences.codexEnabled && NotchQPreferences.claudeEnabled && !NotchQPreferences.onlyRunningApps, "both sources on and detected by installation by default")
    let connection = NotchQClaudeConnection(directory: home.appendingPathComponent("presence"), configuration: home.appendingPathComponent("presence/settings.json"))
    let delegate = NotchQAppDelegate(claudeConnection: connection)
    var running: Set<String> = []
    delegate.locator = NotchQExecutableLocator(home: home.appendingPathComponent("empty"), systemDirectories: [], applicationDirectories: [], applicationURL: { _ in nil }, chosenPath: { _ in nil })
    delegate.runningIdentifiers = { running }
    precondition(delegate.notchQAvailableProviders().isEmpty, "uninstalled sources stay hidden")
    running = [NotchQProvider.claude.bundleIdentifier]
    precondition(delegate.notchQAvailableProviders() == [.claude], "a running desktop app counts as present")
    running = []
    delegate.locator = locator
    precondition(delegate.notchQAvailableProviders() == [.codex, .claude], "installed CLIs are present without their desktop apps")
    defaults.set(false, forKey: "claudeEnabled")
    precondition(delegate.notchQAvailableProviders() == [.codex], "disabled source hidden even when installed")
    defaults.set(true, forKey: "claudeEnabled"); defaults.set(true, forKey: "onlyRunningApps")
    precondition(delegate.notchQAvailableProviders().isEmpty, "desktop filter still limits to running apps")
}

private func runNotchQBridgeRepairChecks(_ home: URL) {
    let config = home.appendingPathComponent("bridge/settings.json")
    let connection = NotchQClaudeConnection(directory: home.appendingPathComponent("bridge/cache"), configuration: config)
    try! FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "printf old"], "other": 1]).write(to: config)
    let moved = URL(fileURLWithPath: home.appendingPathComponent("Old Place/Bob's NotchQ.app/Contents/MacOS/NotchQ").path)
    precondition(NotchQClaudeConnection.notchQBridgeExecutable(NotchQClaudeConnection.notchQBridgeCommand(moved)) == moved.path, "bridge command quoting round-trips")
    try! connection.notchQConnect(executable: moved)
    let current = Bundle.main.executableURL!
    precondition(try! connection.notchQRepairExecutablePath(current), "bridge to a missing copy is repaired")
    let repaired = try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    precondition((repaired["statusLine"] as! [String: Any])["command"] as? String == NotchQClaudeConnection.notchQBridgeCommand(current) && repaired["other"] as? Int == 1 && connection.isConnected, "bridge points at the running copy")
    precondition(connection.notchQOriginalStatusCommand() == "printf old", "original status line still restorable")
    precondition(!(try! connection.notchQRepairExecutablePath(URL(fileURLWithPath: "/Applications/Other/NotchQ"))), "a bridge to an existing copy is left alone")
    try! connection.notchQDisconnect()
    let restored = try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    precondition((restored["statusLine"] as! [String: Any])["command"] as? String == "printf old", "disconnect after repair restores the original")
    precondition(!(try! connection.notchQRepairExecutablePath(current)), "no bridge, nothing to repair")
}

func runNotchQDetectionReport() {
    let locator = NotchQExecutableLocator()
    let started = Date()
    let path = NotchQExecutableLocator.notchQReadLoginPath()
    print(String(format: "launch PATH entries=%d; login-shell PATH %@ in %.2fs", (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").count,
                 path.map { "captured (\($0.count) entries)" } ?? "unavailable", Date().timeIntervalSince(started)))
    locator.loginPath = path ?? []
    for provider in NotchQProvider.allCases {
        guard let location = locator.notchQLocate(provider) else { print("\(provider.displayName): not found"); continue }
        print("\(provider.displayName): \(location.source == .chosen ? "chosen" : "automatic") \((location.url.path as NSString).abbreviatingWithTildeInPath)")
    }
}
