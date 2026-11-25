import AppKit
import UserNotifications

/// One low-limit reminder: a provider's short (5-hour, 1-hour, …) or long (weekly, monthly, …) limit has reached
/// the warning threshold.
struct NotchQReminder: Equatable {
    let provider: NotchQProvider
    let limit: NotchQLowLimit
    let remaining: Int
    let reset: Date?
    var resetDescription: String? = nil
    /// The real window, as said in a sentence ("monthly", "weekly", "5-hour", "usage"); from `NotchQUsageWindow.spokenName`.
    var windowName: String
    /// One card and one notification per provider and limit class; a newer reminder replaces an older one.
    var id: String { "\(provider.rawValue).\(limit.rawValue)" }
    var title: String { "\(provider.displayName) \(windowName) limit almost used up" }
    init(provider: NotchQProvider, limit: NotchQLowLimit, remaining: Int, reset: Date?, resetDescription: String? = nil, windowName: String? = nil) {
        self.provider = provider; self.limit = limit; self.remaining = remaining; self.reset = reset; self.resetDescription = resetDescription
        self.windowName = windowName ?? (limit == .weekly ? "weekly" : "5-hour")
    }
    init(provider: NotchQProvider, limit: NotchQLowLimit, window: NotchQUsageWindow) {
        self.init(provider: provider, limit: limit, remaining: window.remaining, reset: window.reset, resetDescription: window.resetDescription, windowName: window.spokenName)
    }
    func notchQDetail(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        "\(remaining)% left · " + notchQReminderResetText(reset: reset, description: resetDescription, now: now, timeZone: timeZone)
    }
}

/// "resets at 14:05 (in 2 h 10 min)", "resets Fri 09:00 (in 2 d 3 h)", or the provider's own reset text.
func notchQReminderResetText(reset: Date?, description: String?, now: Date, timeZone: TimeZone) -> String {
    if let reset = reset, reset > now {
        let format = DateFormatter(); format.timeZone = timeZone
        format.setLocalizedDateFormatFromTemplate(reset.timeIntervalSince(now) < 86_400 ? "jjmm" : "EEEjjmm")
        return "resets \(reset.timeIntervalSince(now) < 86_400 ? "at " : "")\(format.string(from: reset)) (in \(notchQDurationText(reset.timeIntervalSince(now))))"
    }
    if let description = description { return "resets " + notchQLocalResetText(description, timeZone: timeZone) }
    return "reset time unavailable"
}

/// Remembers which limits were already reminded, so each limit is reminded once per reset period.
/// Stored as "provider.limit" → the period's reset time (seconds since 1970; 0 when the provider gave none).
struct NotchQReminderLedger {
    static let defaultsKey = "lowLimitReminded"
    /// `nil` keeps the ledger in memory only (tests and diagnostic runs).
    let defaults: UserDefaults?
    private(set) var reminded: [String: Double]
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        reminded = (defaults?.dictionary(forKey: Self.defaultsKey) as? [String: Double]) ?? [:]
    }
    private static func key(_ provider: NotchQProvider, _ limit: NotchQLowLimit) -> String { "\(provider.rawValue).\(limit.rawValue)" }
    private func save() { defaults?.set(reminded, forKey: Self.defaultsKey) }

    /// Whether a low limit still needs its reminder for this period; a `true` answer records it as reminded.
    /// Two reset times within `samePeriodTolerance` are the same period (sources round the time differently).
    mutating func notchQShouldRemind(_ provider: NotchQProvider, _ limit: NotchQLowLimit, reset: Date?, now: Date = Date()) -> Bool {
        let key = Self.key(provider, limit), value = reset?.timeIntervalSince1970 ?? 0
        if let old = reminded[key] {
            if old == 0 || value == 0 {
                // Without a reset time on one side, the period is unknown: keep the reminder spent and learn the time.
                if old == 0 && value != 0 { reminded[key] = value; save() }
                return false
            }
            if abs(old - value) <= NotchQUsageSnapshot.samePeriodTolerance { return false }
        }
        // Forget periods that ended more than a day ago, so the ledger never grows.
        reminded = reminded.filter { $0.value == 0 || $0.value > now.timeIntervalSince1970 - 86_400 }
        reminded[key] = value; save()
        return true
    }
    /// A current reading shows this limit above the threshold again. Only a limit whose reset time is unknown
    /// is re-armed: with a known reset, a small rise and fall around the threshold must not remind twice.
    mutating func notchQRecovered(_ provider: NotchQProvider, _ limit: NotchQLowLimit) {
        let key = Self.key(provider, limit)
        if reminded[key] == 0 { reminded[key] = nil; save() }
    }
}

final class NotchQReminderButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchQReminderBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor.black.setFill(); shape.fill()
        NSColor(white: 1, alpha: 0.1).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

/// A reminder card that drops out of the notch (or from under the menu bar on a Mac without one) and stays
/// until its X is clicked. Several cards stack downwards, one per provider and limit.
final class NotchQReminderCardController {
    /// Wide enough for the longest title ("Claude weekly limit almost used up", 226 pt as a 13 pt semibold label)
    /// in full, with the X clear of it.
    static let size = NSSize(width: 360, height: 62)
    static let gap: CGFloat = 8
    struct Card {
        var reminder: NotchQReminder
        let panel: NotchQPanel
        let figure: NSTextField
        let title: NSTextField
        let detail: NSTextField
        let close: NSButton
    }
    private(set) var cards: [Card] = []
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var clock: () -> Date = { Date() }
    /// Called after the user closes a card with its X.
    var onClose: ((NotchQReminder) -> Void)?

    typealias Anchor = (top: CGFloat, midX: CGFloat, notchWidth: CGFloat, screenTop: CGFloat)
    /// Where cards hang from: the bottom edge of the camera housing (notch or Dynamic Island) or menu bar, and the
    /// horizontal centre of the housing.
    static func notchQAnchor() -> Anchor? {
        if let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }),
           let anchor = notchQAnchor(screen: screen.frame, visible: screen.visibleFrame, leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea) {
            return anchor
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return notchQAnchor(screen: screen.frame, visible: screen.visibleFrame, leftArea: nil, rightArea: nil)
    }
    /// The same from given screen areas (macOS's auxiliaryTopLeftArea/auxiliaryTopRightArea, the only documented
    /// description of a camera housing). Any housing width works: a wide notch or a small hole-punch.
    /// Without a housing, cards hang from the menu bar's centre.
    static func notchQAnchor(screen: NSRect, visible: NSRect, leftArea: NSRect?, rightArea: NSRect?) -> Anchor? {
        if let left = leftArea, let right = rightArea {
            guard right.minX > left.maxX else { return nil }
            return (min(left.minY, right.minY), (left.maxX + right.minX) / 2, right.minX - left.maxX, screen.maxY)
        }
        return (visible.maxY, visible.midX, 180, screen.maxY)
    }
    /// The narrowest the opening sliver gets, so a card from a small hole-punch still visibly drops into place.
    static let minimumStartWidth: CGFloat = 60
    /// Where the opening animation starts: a sliver the width of the housing (at least `minimumStartWidth`),
    /// centred on it and tucked under the top edge of the screen.
    static func notchQStartFrame(_ anchor: Anchor) -> NSRect {
        let width = max(minimumStartWidth, anchor.notchWidth)
        return NSRect(x: (anchor.midX - width / 2).rounded(), y: anchor.screenTop - 20, width: width, height: 20)
    }
    /// The resting frame of the card at `index` (0 is closest to the notch).
    static func notchQFrame(index: Int, top: CGFloat, midX: CGFloat) -> NSRect {
        let y = top - gap - CGFloat(index + 1) * size.height - CGFloat(index) * gap
        return NSRect(x: (midX - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    func notchQIsShowing(_ id: String) -> Bool { cards.contains { $0.reminder.id == id } }

    /// Shows a reminder. If its card is already up, the card's text is brought up to date instead.
    func notchQShow(_ reminder: NotchQReminder) {
        if notchQRefresh(reminder) { return }
        let card = notchQMakeCard(reminder)
        cards.append(card)
        guard let anchor = Self.notchQAnchor() else { return }
        let target = Self.notchQFrame(index: cards.count - 1, top: anchor.top, midX: anchor.midX)
        let panel = card.panel
        let content = panel.contentView!.subviews.first { !($0 is NotchQReminderBackground) }
        if reduceMotion() {
            panel.setFrame(target, display: true); panel.alphaValue = 0; panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; panel.animator().alphaValue = 1 }
        } else {
            // Start as a sliver the width of the notch, tucked under it, then drop and widen into place.
            let start = Self.notchQStartFrame(anchor)
            panel.setFrame(start, display: true); panel.alphaValue = 0; content?.alphaValue = 0; panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }, completionHandler: {
                content?.frame = panel.contentView?.bounds ?? .zero
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; content?.animator().alphaValue = 1 }
            })
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "\(reminder.title). \(reminder.notchQDetail(now: clock()))", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Updates a card that is up (a newer percentage or reset time); `false` when it is not showing.
    @discardableResult
    func notchQRefresh(_ reminder: NotchQReminder) -> Bool {
        guard let index = cards.firstIndex(where: { $0.reminder.id == reminder.id }) else { return false }
        cards[index].reminder = reminder
        notchQFill(cards[index])
        return true
    }

    /// Closes a card. `byUser`: the X was clicked, so `onClose` is told.
    func notchQClose(id: String, animated: Bool = true, byUser: Bool = false) {
        guard let index = cards.firstIndex(where: { $0.reminder.id == id }) else { return }
        let card = cards.remove(at: index)
        let panel = card.panel
        if animated && !reduceMotion() {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
                panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 10), display: true)
            }, completionHandler: { panel.orderOut(nil); panel.close() })
        } else { panel.orderOut(nil); panel.close() }
        notchQLayout(animated: animated)
        if byUser { onClose?(card.reminder) }
    }
    func notchQCloseAll() { cards.map(\.reminder.id).forEach { notchQClose(id: $0, animated: false) } }

    /// Puts every card at its resting place (after one closes, or the displays change).
    func notchQLayout(animated: Bool = false) {
        guard let anchor = Self.notchQAnchor() else { return }
        for (index, card) in cards.enumerated() {
            let target = Self.notchQFrame(index: index, top: anchor.top, midX: anchor.midX)
            guard card.panel.frame != target else { continue }
            if animated && !reduceMotion() {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                    card.panel.animator().setFrame(target, display: true)
                }
            } else { card.panel.setFrame(target, display: true) }
        }
    }

    private func notchQFill(_ card: Card) {
        let reminder = card.reminder
        card.figure.attributedStringValue = NSAttributedString(string: "\(reminder.remaining)%", attributes: [
            .font: notchQPercentageFont().map { NSFont(descriptor: $0.fontDescriptor, size: 22) ?? $0 } ?? NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: reminder.provider.color])
        card.title.stringValue = reminder.title
        card.detail.stringValue = reminder.notchQDetail(now: clock())
        card.panel.contentView?.setAccessibilityLabel("\(reminder.title). \(card.detail.stringValue)")
    }

    private func notchQMakeCard(_ reminder: NotchQReminder) -> Card {
        let size = Self.size
        let panel = NotchQPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "NotchQ reminder"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let background = NotchQReminderBackground(frame: root.bounds); background.autoresizingMask = [.width, .height]
        root.addSubview(background)
        // The text sits in a fixed-size box centred in the card, so it never reflows while the card widens.
        let content = NSView(frame: root.bounds); content.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(content)
        func label(_ font: NSFont, _ color: NSColor) -> NSTextField {
            let field = NSTextField(labelWithString: ""); field.font = font; field.textColor = color
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1; return field
        }
        let figure = label(.systemFont(ofSize: 22), reminder.provider.color); figure.alignment = .center
        figure.frame = NSRect(x: 12, y: (size.height - 30) / 2, width: 58, height: 30)
        let title = label(.systemFont(ofSize: 13, weight: .semibold), .white)
        title.frame = NSRect(x: 76, y: 32, width: size.width - 76 - 42, height: 18)
        let detail = label(.systemFont(ofSize: 11.5), NSColor(white: 1, alpha: 0.62))
        detail.frame = NSRect(x: 76, y: 13, width: size.width - 76 - 42, height: 16)
        let close = NotchQReminderButton(frame: NSRect(x: size.width - 36, y: (size.height - 24) / 2, width: 24, height: 24))
        close.isBordered = false; close.bezelStyle = .regularSquare; close.focusRingType = .none
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close reminder")
        close.imageScaling = .scaleProportionallyUpOrDown; close.contentTintColor = NSColor(white: 1, alpha: 0.55)
        if close.image == nil { close.title = "✕" }
        close.setAccessibilityLabel("Close reminder"); close.toolTip = "Close"
        close.identifier = NSUserInterfaceItemIdentifier(reminder.id)
        close.target = self; close.action = #selector(notchQCloseClicked(_:))
        for view in [figure, title, detail, close] as [NSView] { content.addSubview(view) }
        root.setAccessibilityElement(true); root.setAccessibilityRole(.group)
        panel.contentView = root
        let card = Card(reminder: reminder, panel: panel, figure: figure, title: title, detail: detail, close: close)
        notchQFill(card)
        return card
    }

    @objc private func notchQCloseClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        notchQClose(id: id, byUser: true)
    }
}

/// The optional macOS notification for a reminder. macOS shows it as a banner that slides away unless the
/// user picks the Alerts style for NotchQ, so turning it on shows a one-time tip about that.
final class NotchQReminderNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let alertsTipKey = "didShowNotificationAlertsTip"
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current(); center.delegate = self; return center
    }()

    func notchQRequestPermission(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in DispatchQueue.main.async { completion(granted) } }
    }
    func notchQDeliver(_ reminder: NotchQReminder) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.notchQDetail()
        content.sound = .default; content.threadIdentifier = "lowLimit"
        // The same identifier replaces an older notification for this limit instead of piling up.
        center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: nil))
    }
    func notchQWithdraw(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id]); center.removePendingNotificationRequests(withIdentifiers: [id])
    }
    /// NotchQ is a menu-bar app; show its notifications even while it happens to be the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    static var notificationSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? NotchQPreferences.applicationIdentifier)")!
    }
    static let alertsTipText = "macOS shows notifications as banners that slide away after a few seconds. To keep a low-limit reminder on screen until you close it, open System Settings → Notifications → NotchQ and choose Alerts."
    /// The tip about the Alerts style, once per Mac. Returns whether it was shown.
    @discardableResult
    static func notchQShowAlertsTipIfNeeded(defaults: UserDefaults = NotchQPreferences.defaults) -> Bool {
        guard !defaults.bool(forKey: alertsTipKey) else { return false }
        defaults.set(true, forKey: alertsTipKey)
        let alert = NSAlert(); alert.messageText = "Tip: keep reminders on screen"
        alert.informativeText = alertsTipText
        alert.addButton(withTitle: "Open Notification Settings"); alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(notificationSettingsURL) }
        return true
    }
}
