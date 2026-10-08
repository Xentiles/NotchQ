import AppKit
import CoreText

func runNotchQChecks() {
    var count = 0
    func notchQAssert(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label); count += 1
    }
    func notchQFixture(_ used: Any, secondary: Double? = nil) -> [String: Any] {
        var limits: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": used, "windowDurationMins": 10080, "resetsAt": 1791969855]]
        if let secondary = secondary { limits["secondary"] = ["usedPercent": secondary, "windowDurationMins": 300] }
        return ["rateLimits": limits]
    }
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(47))?.remaining == 53, "remaining conversion")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(47.2))?.remaining == 52, "conservative rounding")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(-10))?.remaining == 100, "clamp high")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(120))?.remaining == 0, "clamp low")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(47, secondary: 91))?.remaining == 9, "tightest window")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(true)) == nil, "reject boolean")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(Double.nan)) == nil, "reject nonfinite")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture("47")) == nil, "reject string")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits([:]) == nil, "absent limits")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(["rateLimits": ["primary": NSNull()]]) == nil, "null windows")
    let grouped: [String: Any] = ["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 80]]], "rateLimits": ["primary": ["usedPercent": 10]]]
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(grouped)?.remaining == 20, "prefer grouped codex")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(["rateLimits": ["limitId": "other", "primary": ["usedPercent": 80]]]) == nil, "no other bucket")
    notchQAssert(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(47))?.windows.first?.label == "Weekly", "window labeling")
    var state = NotchQUsageState()
    let now = Date(timeIntervalSince1970: 1000)
    notchQAssert(state.percentage == "—%", "initial unavailable")
    state.notchQRecordSuccess(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(47))!, now: now)
    notchQAssert(state.percentage == "53%", "success display")
    state.notchQRecordFailure("timeout", now: now)
    notchQAssert(state.percentage == "—%" && state.snapshot?.remaining == 53, "stale data hidden but retained")
    notchQAssert(state.nextAllowed.timeIntervalSince(now) == 10, "initial backoff")
    state.notchQRecordFailure("throttled", now: now, retryAfter: 90)
    notchQAssert(state.nextAllowed.timeIntervalSince(now) == 90, "respect retry-after")
    state.notchQRecordSuccess(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(10))!, now: now)
    notchQAssert(state.percentage == "90%" && state.failures == 0 && state.nextAllowed == .distantPast, "recovery")
    let title = notchQPercentageTitle("53%")
    notchQAssert(title.string == "53%", "percentage-only marker")
    let digitFont = title.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    let percentFont = title.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
    notchQAssert(digitFont.fontName == percentFont.fontName, "digits and percent share font")
    let screen = NSRect(x: 0, y: 0, width: 1710, height: 1107)
    let left = NSRect(x: 0, y: 1074, width: 763, height: 33)
    let right = NSRect(x: 948, y: 1074, width: 762, height: 33)
    let placement = NotchQPlacement.notchQFrame(screen: screen, leftArea: left, rightArea: right)!
    notchQAssert(placement.maxX == left.maxX - 8 && left.contains(placement), "left of notch, never obscured")
    notchQAssert(placement.midY == left.midY, "center in the menu-bar strip")
    notchQAssert(NotchQPlacement.notchQFrame(screen: screen, leftArea: nil, rightArea: nil) == nil, "no notch fallback")
    let shifted = NotchQPlacement.notchQFrame(screen: screen.offsetBy(dx: -1710, dy: 100), leftArea: left.offsetBy(dx: -1710, dy: 100), rightArea: right.offsetBy(dx: -1710, dy: 100))!
    notchQAssert(shifted.origin == placement.offsetBy(dx: -1710, dy: 100).origin, "global multi-display coordinates")
    notchQAssert(NotchQProvider.notchQRunning(in: []) == [], "neither running hides badge")
    notchQAssert(NotchQProvider.notchQRunning(in: [NotchQProvider.codex.bundleIdentifier]) == [.codex], "codex only")
    notchQAssert(NotchQProvider.notchQRunning(in: [NotchQProvider.claude.bundleIdentifier]) == [.claude], "claude only")
    notchQAssert(NotchQProvider.notchQRunning(in: [NotchQProvider.codex.bundleIdentifier, NotchQProvider.claude.bundleIdentifier]) == [.codex, .claude], "both apps ordered consistently")
    notchQAssert(NotchQProvider.notchQRunning(in: [notchQApplicationIdentifier]) == [], "helper process is not a provider")
    let dual = notchQProviderTitle([.codex, .claude], codex: "51%")
    notchQAssert(dual.string == "51%  —%", "unknown Claude percentage remains unavailable")
    notchQAssert((dual.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .white, "codex is white")
    notchQAssert((dual.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor) == NotchQProvider.claude.color, "claude is orange")
    notchQAssert((dual.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.fontName == digitFont.fontName, "both providers use Libron")
    let wide = NotchQPlacement.notchQFrame(screen: screen, leftArea: left, rightArea: right, width: 116)!
    notchQAssert(left.contains(wide) && wide.maxX == placement.maxX, "dual badge stays left of notch")
    for value in ["0%", "49%", "100%"] {
        let layout = NotchQBadgeLayout(notchQPercentageTitle(value))
        let box = NSRect(origin: .zero, size: layout.size)
        let origin = layout.notchQOrigin(in: box)
        let edges = [origin.x + layout.ink.minX, box.width - (origin.x + layout.ink.maxX), origin.y + layout.ink.minY, box.height - (origin.y + layout.ink.maxY)]
        notchQAssert(edges.allSatisfy { abs($0 - NotchQBadgeLayout.padding) < 0.001 }, "equal ink padding for \(value)")
    }
    var good = NotchQUsageState(); good.notchQRecordSuccess(NotchQUsageSnapshot.notchQParseCodexLimits(notchQFixture(0))!)
    let missing = NotchQUsageState()
    notchQAssert(NotchQProvider.notchQDisplayed(running: [.codex, .claude], codex: good, claude: missing) == [.codex], "hide provider without reading")
    notchQAssert(NotchQProvider.notchQDisplayed(running: [.codex, .claude], codex: good, claude: good) == [.codex, .claude], "both verified providers")
    var failed = good; failed.notchQRecordFailure("unavailable")
    notchQAssert(NotchQProvider.notchQDisplayed(running: [.codex], codex: failed, claude: missing).isEmpty, "hide failed provider")
    notchQAssert(good.percentage == "100%", "zero used is still a valid reading")
    for width: CGFloat in [1280, 1440, 1512, 1710, 1920] {
        for camera: CGFloat in [150, 185, 240] {
            let full = NSRect(x: -width, y: 100, width: width, height: 1000)
            let left = NSRect(x: full.minX, y: full.maxY - 33, width: (width - camera) / 2, height: 33)
            let right = NSRect(x: left.maxX + camera, y: left.minY, width: left.width, height: 33)
            let badge = NotchQPlacement.notchQFrame(screen: full, leftArea: left, rightArea: right, width: 90, height: 22)
            notchQAssert(badge != nil && left.contains(badge!), "reported geometry adapts across notch widths")
        }
    }
    notchQAssert(NotchQPlacement.notchQFrame(screen: screen, leftArea: left, rightArea: right, width: .nan) == nil, "invalid geometry fails closed")
    notchQAssert(NotchQPlacement.notchQFrame(screen: screen, leftArea: left, rightArea: right, height: 50) == nil, "oversized badge falls back")
    print("Passed \(count) usage, recovery, typography and display-geometry checks; percentage font=\(digitFont.fontName)")
    runNotchQClaudeChecks()
}

func runNotchQTransportChecks(_ server: URL) {
    let mode = server.appendingPathExtension("mode")
    defer { try? FileManager.default.removeItem(at: mode) }
    let client = NotchQCodexClient(); client.executableOverride = server; client.timeout = 0.35
    defer { client.notchQStopClient(wait: true) }
    var checks = 0
    func notchQFetchUsage(_ scenario: String) -> Result<NotchQUsageSnapshot, NotchQCodexError> {
        try! scenario.write(to: mode, atomically: true, encoding: .utf8)
        var received: Result<NotchQUsageSnapshot, NotchQCodexError>?
        client.notchQFetchUsage { received = $0 }
        let deadline = Date().addingTimeInterval(3)
        while received == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(received != nil, "test callback missing: \(scenario)")
        checks += 1
        return received!
    }
    if case .success(let value) = notchQFetchUsage("success") { precondition(value.remaining == 53) } else { preconditionFailure("success fixture") }
    client.notchQStopClient(wait: true)
    if case .failure(.timeout) = notchQFetchUsage("timeout") {} else { preconditionFailure("timeout fixture") }
    if case .success = notchQFetchUsage("success") {} else { preconditionFailure("recovery fixture") }
    client.notchQStopClient(wait: true)
    if case .failure(.disconnected) = notchQFetchUsage("disconnect") {} else { preconditionFailure("disconnect fixture") }
    if case .failure(.rejected(_, let retry)) = notchQFetchUsage("throttle") { precondition(retry == 60) } else { preconditionFailure("throttle fixture") }
    client.notchQStopClient(wait: true)
    try! "success".write(to: mode, atomically: true, encoding: .utf8)
    var callbacks = 0
    client.notchQFetchUsage { _ in callbacks += 1 }; client.notchQFetchUsage { _ in callbacks += 100 }
    let deadline = Date().addingTimeInterval(1)
    while callbacks == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(callbacks == 1, "only one in-flight request")
    checks += 1
    print("Passed \(checks) transport checks: fragmented messages, timeout, reconnect, disconnect, throttling, single-flight")
}

func renderNotchQFontPreview(_ path: String) {
    _ = NSApplication.shared
    let image = NSImage(size: NSSize(width: 700, height: 240))
    image.lockFocus()
    for (row, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let y = CGFloat(120 - row * 120)
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: y, width: 700, height: 120).fill()
            for (column, value) in ["0%", "53%", "100%", "—%"].enumerated() {
                notchQPercentageTitle(value).draw(at: NSPoint(x: 20 + column * 170, y: Int(y) + 55))
            }
        }
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Preview rendered; percentage font=\(notchQPercentageFont()?.fontName ?? "system fallback")")
}

func runNotchQLifecycleChecks(_ server: URL) {
    _ = NSApplication.shared
    let mode = server.appendingPathExtension("mode")
    try! "success".write(to: mode, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: mode) }
    let delegate = NotchQAppDelegate()
    delegate.testingLifecycle = true
    delegate.client.executableOverride = server
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    func notchQSettle() {
        let until = Date().addingTimeInterval(2)
        while delegate.client.busy && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    notchQSettle()
    precondition(delegate.state.percentage == "53%")
    let previousPID = delegate.client.processIdentifier!
    delegate.notchQWillSleep()
    precondition(delegate.sleeping && delegate.timer?.isValid == false && delegate.client.processIdentifier == nil)
    delegate.notchQRefreshUsage()
    precondition(delegate.client.processIdentifier == nil, "no asleep polling")
    delegate.notchQDidWake(); notchQSettle()
    precondition(!delegate.sleeping && delegate.timer?.isValid == true && delegate.state.percentage == "53%")
    precondition(delegate.client.processIdentifier != previousPID, "wake reconnects")
    delegate.menuWillOpen(delegate.item.menu!)
    let titles = delegate.item.menu!.items.map(\.title)
    precondition(titles.contains("Refresh now") && titles.contains("Open Codex") && titles.contains("Start at login") && titles.contains("Quit"))
    delegate.testPresence = [.codex, .claude]; delegate.notchQUpdateProviderPresence()
    precondition(delegate.notch?.button.attributedTitle.string == "53%", "unavailable Claude hidden")
    delegate.claudeState.notchQRecordSuccess(NotchQUsageSnapshot.notchQParseCodexLimits(["rateLimits": ["primary": ["usedPercent": 20]]])!)
    delegate.notchQRenderBadge()
    precondition(delegate.notch?.button.attributedTitle.string == "53%  80%")
    precondition(delegate.notch?.currentFrame?.width == NotchQBadgeLayout(delegate.notch!.button.attributedTitle).size.width)
    delegate.claudeState.notchQRecordFailure("unavailable"); delegate.notchQRenderBadge()
    delegate.testPresence = [.claude]; delegate.notchQUpdateProviderPresence(); delegate.notchQRefreshUsage()
    precondition(delegate.client.processIdentifier == nil, "no Codex polling when its app is closed")
    precondition(!delegate.item.isVisible && delegate.notch?.currentFrame == nil, "unavailable-only provider hides badge")
    delegate.testPresence = []; delegate.notchQUpdateProviderPresence()
    precondition(!delegate.item.isVisible && delegate.notch?.currentFrame == nil, "neither provider hides all UI")
    delegate.testPresence = [.codex]; delegate.notchQUpdateProviderPresence()
    precondition(delegate.state.percentage == "—%", "reopened provider waits for fresh data")
    delegate.notchQRefreshUsage(); notchQSettle()
    precondition(delegate.state.percentage == "53%" && delegate.client.processIdentifier != nil)
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    precondition(delegate.timer?.isValid == false && delegate.client.processIdentifier == nil)
    NSStatusBar.system.removeStatusItem(delegate.item)
    print("Passed lifecycle checks: sleep/wake, menu actions, all provider transitions, conditional polling, shutdown")
}

func renderNotchQNotchPreview(_ path: String) {
    _ = NSApplication.shared
    let image = NSImage(size: NSSize(width: 620, height: 150))
    image.lockFocus()
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 620, height: 150).fill()
    let camera = NSRect(x: 218, y: 117, width: 185, height: 33)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: camera, xRadius: 10, yRadius: 10).fill()
    NSRect(x: camera.minX, y: 140, width: camera.width, height: 10).fill()
    let marker = NSRect(x: camera.minX - 66, y: 120, width: 58, height: 30)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: marker.insetBy(dx: 0, dy: 3), xRadius: 8, yRadius: 8).fill()
    let text = notchQPercentageTitle("53%", color: .white)
    let size = text.size()
    text.draw(at: NSPoint(x: marker.midX - size.width / 2, y: marker.midY - size.height / 2))
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Notch preview rendered")
}

func renderNotchQProviderPreview(_ path: String) {
    _ = NSApplication.shared
    let image = NSImage(size: NSSize(width: 660, height: 160))
    image.lockFocus()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 660, height: 160).fill()
    let examples: [(String, [NotchQProvider])] = [("Codex only", [.codex]), ("Claude Free only", [.claude]), ("Both running", [.codex, .claude])]
    for (index, example) in examples.enumerated() {
        let x = CGFloat(index * 220)
        let width: CGFloat = example.1.count == 2 ? 116 : 58
        let badge = NSRect(x: x + 110 - width / 2, y: 70, width: width, height: 30)
        NSColor.black.setFill(); NSBezierPath(roundedRect: badge.insetBy(dx: 0, dy: 3), xRadius: 8, yRadius: 8).fill()
        let title = notchQProviderTitle(example.1, codex: "51%")
        let size = title.size()
        title.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        let label = NSAttributedString(string: example.0, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        label.draw(at: NSPoint(x: x + 110 - label.size().width / 2, y: 38))
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Provider preview rendered")
}

func renderNotchQPaddingPreview(_ path: String) {
    _ = NSApplication.shared
    let image = NSImage(size: NSSize(width: 660, height: 180))
    image.lockFocus()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 660, height: 180).fill()
    let examples = [notchQProviderTitle([.codex], codex: "0%"), notchQProviderTitle([.codex], codex: "100%"), notchQProviderTitle([.codex, .claude], codex: "49%", claude: "80%")]
    for (index, title) in examples.enumerated() {
        let layout = NotchQBadgeLayout(title)
        let badge = NSRect(x: CGFloat(index * 220) + 110 - layout.size.width / 2, y: 85, width: layout.size.width, height: layout.size.height)
        NSColor.black.setFill(); NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState(); context.textMatrix = .identity
        let origin = layout.notchQOrigin(in: NSRect(origin: .zero, size: badge.size))
        context.textPosition = CGPoint(x: badge.minX + origin.x, y: badge.minY + origin.y)
        CTLineDraw(notchQCoreTextLine(title), context); context.restoreGState()
        let label = NSAttributedString(string: "6 pt on every side", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        label.draw(at: NSPoint(x: CGFloat(index * 220) + 110 - label.size().width / 2, y: 48))
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Uniform ink-padding preview rendered")
}
