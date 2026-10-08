import AppKit

func renderNotchQSettingsPreview(_ path: String) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-ui-preview")
    let connection = NotchQClaudeConnection(directory: directory, configuration: directory.appendingPathComponent("settings.json"))
    let controller = NotchQSettingsController(connection: connection)
    controller.notchQRefreshSettings(codexMessage: "Uses your installed Codex sign-in. Read-only checks every 10 seconds.", claudeMessage: "Connect Claude Code to receive recent usage snapshots on supported plans.")
    let view = controller.window.contentView!
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { preconditionFailure("No settings bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Native Settings preview rendered")
}
