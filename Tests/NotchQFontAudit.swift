import AppKit
import CoreText

final class NotchQFontAudit: NSObject, NSApplicationDelegate {
    let badge = NotchQBadgeController()
    let directory: URL
    let menu = NSMenu()
    let pairs = [("88%", "88%"), ("92%", "92%"), ("13%", "13%"), ("0%", "0%"), ("100%", "100%"), ("86%", "92%")]
    init(directory: URL) { self.directory = directory; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        badge.panel.title = "NotchQ Font Comparison (test values)"
        let label = NSMenuItem(title: "Illustrative font test — no usage queries", action: nil, keyEquivalent: "")
        label.isEnabled = false; menu.addItem(label); menu.addItem(.separator())
        for (index, pair) in pairs.enumerated() {
            let item = NSMenuItem(title: "\(pair.0) / \(pair.1)", action: #selector(selectPair(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close font test", action: #selector(closeTest), keyEquivalent: "q")
        close.target = self; menu.addItem(close)
        badge.onClick = { [weak self] in
            guard let self = self else { return }
            self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: self.badge.button)
        }
        showPair(0)
    }
    @objc func selectPair(_ sender: NSMenuItem) { showPair(sender.tag) }
    func showPair(_ index: Int) {
        let pair = pairs[index]
        let title = notchQProviderTitle([.codex, .claude], codex: pair.0, claude: pair.1)
        badge.notchQUpdateBadge(title: title, indicatorCount: 2, tooltip: "Font test only: \(pair.0) / \(pair.1)")
        badge.button.alphaValue = 1
        precondition(badge.notchQPositionBadge(animated: false, reassert: true), "Font audit needs a usable notch screen")
        let orangeIndex = pair.0.utf16.count + 2
        let whiteFont = title.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let orangeFont = title.attribute(.font, at: orangeIndex, effectiveRange: nil) as! NSFont
        let whiteBaseline = title.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        let orangeBaseline = title.attribute(.baselineOffset, at: orangeIndex, effectiveRange: nil) as? CGFloat ?? 0
        let layout = NotchQBadgeLayout(title)
        let report: [String: Any] = ["values": [pair.0, pair.1], "fontNames": [whiteFont.fontName, orangeFont.fontName],
            "pointSizes": [whiteFont.pointSize, orangeFont.pointSize], "baselineOffsets": [whiteBaseline, orangeBaseline],
            "inkHeightPoints": layout.ink.height, "badgeSizePoints": [layout.size.width, layout.size.height],
            "backingScale": badge.panel.backingScaleFactor]
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("font-metrics-\(index).json"))
        let view = badge.panel.contentView!
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("render-\(index).png"))
        }
        print("Font comparison: \(pair.0) / \(pair.1); point sizes \(whiteFont.pointSize) / \(orangeFont.pointSize); baseline offsets \(whiteBaseline) / \(orangeBaseline)")
        fflush(stdout)
    }
    @objc func closeTest() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { badge.notchQCloseBadge() }
}

func runNotchQFontAudit(_ directory: URL) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let audit = NotchQFontAudit(directory: directory)
    app.delegate = audit
    withExtendedLifetime(audit) { app.run() }
}

func renderNotchQFontControls(_ directory: URL) {
    _ = NSApplication.shared
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let badge = NotchQBadgeController()
    defer { badge.notchQCloseBadge() }
    let original = notchQProviderTitle([.codex, .claude], codex: "88%", claude: "88%")
    for (name, colors) in [("normal", [NSColor.white, NotchQProvider.claude.color]),
                           ("white", [NSColor.white, NSColor.white]),
                           ("orange", [NotchQProvider.claude.color, NotchQProvider.claude.color]),
                           ("swapped", [NotchQProvider.claude.color, NSColor.white])] {
        let title = NSMutableAttributedString(attributedString: original)
        title.addAttribute(.foregroundColor, value: colors[0], range: NSRange(location: 0, length: 3))
        title.addAttribute(.foregroundColor, value: colors[1], range: NSRange(location: 5, length: 3))
        badge.notchQUpdateBadge(title: title, indicatorCount: 2, tooltip: "Font control")
        let size = NotchQBadgeLayout(title).size
        badge.panel.setFrame(NSRect(origin: .zero, size: size), display: true)
        let view = badge.panel.contentView!; view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("control-\(name).png"))
    }
    print("Rendered same-color and swapped-color controls with identical font attributes")
}
