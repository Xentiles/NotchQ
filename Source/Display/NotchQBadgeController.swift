import AppKit
import CoreText
import QuartzCore

func notchQCoreTextLine(_ title: NSAttributedString) -> CTLine {
    let text = NSMutableAttributedString(attributedString: title)
    title.enumerateAttributes(in: NSRange(location: 0, length: title.length)) { attributes, range, _ in
        if let font = attributes[.font] as? NSFont {
            text.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: font as CTFont, range: range)
        }
        if let color = attributes[.foregroundColor] as? NSColor {
            text.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor, range: range)
        }
    }
    return CTLineCreateWithAttributedString(text)
}

struct NotchQBadgeLayout {
    static let padding: CGFloat = 6
    let ink: CGRect
    let size: NSSize
    init(_ title: NSAttributedString) {
        let line = notchQCoreTextLine(title)
        let bounds = CTLineGetImageBounds(line, nil)
        ink = bounds.isNull || bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
        size = NSSize(width: ink.width + Self.padding * 2, height: ink.height + Self.padding * 2)
    }
    func notchQOrigin(in bounds: NSRect) -> CGPoint {
        CGPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
    }
}

/// Draws a badge title centred on its ink. `layout` is always the full title, so a partly transparent
/// copy of it lands on exactly the same baseline and positions.
func notchQDrawBadgeTitle(_ title: NSAttributedString, layout full: NSAttributedString, in view: NSView) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let line = notchQCoreTextLine(title)
    let layout = NotchQBadgeLayout(full)
    context.saveGState()
    // NSButton is flipped; CoreText expects a bottom-left coordinate system.
    if view.isFlipped { context.translateBy(x: 0, y: view.bounds.height); context.scaleBy(x: 1, y: -1) }
    context.textMatrix = .identity
    context.textPosition = layout.notchQOrigin(in: view.bounds)
    CTLineDraw(line, context)
    context.restoreGState()
}

final class NotchQBadgeButton: NSButton {
    /// Figures drawn by the pulse layer instead (see NotchQPulseView).
    var hiddenRanges: [NSRange] = [] { didSet { if hiddenRanges != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        notchQDrawBadgeTitle(hiddenRanges.isEmpty ? attributedTitle : notchQMaskedTitle(attributedTitle, ranges: hiddenRanges, keep: false), layout: attributedTitle, in: self)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// How a nearly used-up limit blinks. Only opacity changes, never colour, and every step is eased.
/// - 5-hour: a soft, slow pulse (the blink the weekly warning used up to 0.4.1): 1.0 to 0.25 and back over 2 s.
/// - Weekly: a sharp double pulse, faster and stronger: two quick dips to 0.1, then a rest, every 1.4 s.
struct NotchQPulseRhythm: Equatable {
    let opacities: [Float]
    let keyTimes: [Double]
    let duration: CFTimeInterval
    /// One timing function per step between key times.
    let easing: [CAMediaTimingFunctionName]
    static let fiveHour = NotchQPulseRhythm(opacities: [1, 0.25, 1], keyTimes: [0, 0.5, 1], duration: 2.0,
                                            easing: [.easeInEaseOut, .easeInEaseOut])
    static let weekly = NotchQPulseRhythm(opacities: [1, 0.1, 1, 0.1, 1, 1], keyTimes: [0, 0.1, 0.22, 0.32, 0.46, 1], duration: 1.4,
                                          easing: [.easeOut, .easeIn, .easeOut, .easeIn, .linear])
    static func notchQFor(_ limit: NotchQLowLimit) -> NotchQPulseRhythm { limit == .weekly ? .weekly : .fiveHour }
    var lowestOpacity: Float { opacities.min() ?? 1 }
    func notchQAnimation() -> CAKeyframeAnimation {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = opacities; pulse.keyTimes = keyTimes.map { NSNumber(value: $0) }
        pulse.timingFunctions = easing.map { CAMediaTimingFunction(name: $0) }
        pulse.duration = duration; pulse.repeatCount = .infinity; pulse.isRemovedOnCompletion = false
        return pulse
    }
}

/// A see-through layer over a badge that draws only the figures of providers whose shown limit is nearly
/// used up, so those figures alone can blink. There is one layer per rhythm (5-hour and weekly), so two
/// providers can blink differently at the same time. Core Animation runs the loop; nothing is redrawn per frame.
/// With Reduce Motion the figure does not move: it is shown steadily dimmed instead.
final class NotchQPulseView: NSView {
    static let animationKey = "notchQPulse"
    static let staticOpacity: CGFloat = 0.6      // Reduce Motion: a steady dim instead of a pulse
    let rhythm: NotchQPulseRhythm
    var drawContent: ((NotchQPulseView) -> Void)?
    var drawsFlipped = false
    init(rhythm: NotchQPulseRhythm = .weekly) { self.rhythm = rhythm; super.init(frame: .zero) }
    required init?(coder: NSCoder) { rhythm = .weekly; super.init(coder: coder) }
    override var isFlipped: Bool { drawsFlipped }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the badge underneath
    override func draw(_ dirtyRect: NSRect) { drawContent?(self) }
    private(set) var animating = false
    private(set) var staticCue = false
    /// How often the loop was (re)started; a steady pulse is started once, not on every refresh.
    private(set) var starts = 0

    /// - shown: there is a figure to draw. - animate: its badge is on screen and the Mac is awake.
    func notchQApply(shown: Bool, animate: Bool, reduceMotion: Bool) {
        wantsLayer = true
        isHidden = !shown
        staticCue = shown && reduceMotion
        alphaValue = staticCue ? Self.staticOpacity : 1
        let run = shown && animate && !reduceMotion
        if run {
            // Core Animation drops the loop when the layer leaves the screen; add it only when it is missing.
            if !animating || layer?.animation(forKey: Self.animationKey) == nil {
                layer?.add(rhythm.notchQAnimation(), forKey: Self.animationKey); starts += 1
            }
        } else { layer?.removeAnimation(forKey: Self.animationKey) }
        animating = run
    }
}

/// The figures to blink, by the limit that is low; ranges are positions in the badge title.
typealias NotchQPulseRanges = [NotchQLowLimit: [NSRange]]
extension Dictionary where Key == NotchQLowLimit, Value == [NSRange] {
    /// Every blinking figure, whatever its rhythm (the badge itself leaves all of them out).
    var notchQAll: [NSRange] { NotchQLowLimit.allCases.flatMap { self[$0] ?? [] } }
}

struct NotchQPlacement {
    static func notchQFrame(screen: NSRect, leftArea: NSRect?, rightArea: NSRect?, width: CGFloat = 58, height desiredHeight: CGFloat = 30) -> NSRect? {
        guard width.isFinite, desiredHeight.isFinite, width > 0, desiredHeight > 0,
              let left = leftArea, let right = rightArea,
              left.height >= desiredHeight, left.width > width + 8,
              right.minX > left.maxX, screen.contains(left), screen.contains(right),
              abs(left.maxY - right.maxY) <= 1, left.maxY <= screen.maxY + 1 else { return nil }
        // Stay entirely in the documented unobscured region, eight points from the camera housing.
        return NSRect(x: left.maxX - width - 8, y: left.midY - desiredHeight / 2, width: width, height: desiredHeight)
    }
}

final class NotchQPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchQBadgeBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

final class NotchQBadgeController {
    let panel: NotchQPanel
    let button: NSButton
    var onClick: (() -> Void)?
    private(set) var currentFrame: NSRect?
    private(set) var badgeSize = NSSize(width: 38, height: 24)
    private var transition = 0
    /// One blinking layer per rhythm; `pulseView` is the weekly one.
    let pulseViews: [NotchQLowLimit: NotchQPulseView] = [.fiveHour: NotchQPulseView(rhythm: .fiveHour), .weekly: NotchQPulseView(rhythm: .weekly)]
    var pulseView: NotchQPulseView { pulseViews[.weekly]! }
    private(set) var pulseRanges: NotchQPulseRanges = [:]
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        panel = NotchQPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "NotchQ"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let backdrop = NotchQBadgeBackground(frame: NSRect(x: 0, y: 0, width: 58, height: 30))
        button = NotchQBadgeButton(frame: backdrop.bounds)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.focusRingType = .none
        button.autoresizingMask = [.width, .height]
        button.setAccessibilityLabel("Codex usage remaining")
        backdrop.addSubview(button)
        for limit in NotchQLowLimit.allCases {
            let view = pulseViews[limit]!
            view.frame = backdrop.bounds; view.autoresizingMask = [.width, .height]; view.drawsFlipped = button.isFlipped
            view.drawContent = { [weak self] view in
                guard let self = self, let ranges = self.pulseRanges[limit], !ranges.isEmpty else { return }
                notchQDrawBadgeTitle(notchQMaskedTitle(self.button.attributedTitle, ranges: ranges, keep: true), layout: self.button.attributedTitle, in: view)
            }
            backdrop.addSubview(view); view.isHidden = true
        }
        panel.contentView = backdrop
        button.target = self
        button.action = #selector(notchQBadgeClicked)
    }

    @discardableResult
    func notchQPositionBadge(show: Bool = true, animated: Bool = true, reassert: Bool = false) -> Bool {
        let candidate = NSScreen.screens.compactMap { screen -> NSRect? in
            NotchQPlacement.notchQFrame(screen: screen.frame, leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea, width: badgeSize.width, height: badgeSize.height)
        }.first
        guard let frame = candidate else { notchQHideBadge(animated: false); return false }
        let previousFrame = currentFrame
        transition += 1
        currentFrame = frame
        let animate = animated && show && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !show { panel.setFrame(frame, display: true); return true }
        if !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = animate ? 0 : 1
            panel.orderFrontRegardless()
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else if animate && previousFrame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
        }
        if reassert {
            button.alphaValue = 1
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        notchQSyncPulse()
        return true
    }

    /// The pulse runs only while the badge is placed beside the notch; hiding it (or sleep) stops the loop.
    func notchQSyncPulse() {
        for (limit, view) in pulseViews {
            view.notchQApply(shown: !(pulseRanges[limit] ?? []).isEmpty, animate: currentFrame != nil, reduceMotion: reduceMotion())
        }
    }

    /// `pulse`: the figures (ranges of `title`) whose shown limit is nearly used up, by that limit.
    func notchQUpdateBadge(title: NSAttributedString, indicatorCount: Int, tooltip: String, pulse: NotchQPulseRanges = [:]) {
        let pulse = pulse.filter { !$0.value.isEmpty }
        if pulse != pulseRanges || !button.attributedTitle.isEqual(to: title) { pulseViews.values.forEach { $0.needsDisplay = true } }
        pulseRanges = pulse; (button as? NotchQBadgeButton)?.hiddenRanges = pulse.notchQAll
        defer { notchQSyncPulse() }
        badgeSize = NotchQBadgeLayout(title).size
        let changed = !button.attributedTitle.isEqual(to: title)
        button.attributedTitle = title
        button.toolTip = tooltip
        button.setAccessibilityLabel("AI usage remaining")
        button.setAccessibilityValue(tooltip)
        if changed && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.alphaValue = 0.45
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                button.animator().alphaValue = 1
            }
        }
        panel.contentView?.needsDisplay = true
    }

    @objc private func notchQBadgeClicked() { onClick?() }
    func notchQHideBadge(animated: Bool = true) {
        transition += 1
        let current = transition
        currentFrame = nil
        notchQSyncPulse()
        guard animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil); panel.alphaValue = 1; return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.transition == current else { return }
            self.panel.orderOut(nil); self.panel.alphaValue = 1
        })
    }
    func notchQCloseBadge() { panel.close() }
}
