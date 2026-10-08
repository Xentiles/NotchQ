import AppKit
import CoreText
import QuartzCore

func notchQCoreTextLine(_ title: NSAttributedString) -> CTLine {
    let text = NSMutableAttributedString(attributedString: title)
    title.enumerateAttributes(in: NSRange(location: 0, length: title.length)) { attributes, range, _ in
        if let font = attributes[.font] as? NSFont {
            text.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil), range: range)
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

final class NotchQBadgeButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = notchQCoreTextLine(attributedTitle)
        let layout = NotchQBadgeLayout(attributedTitle)
        context.saveGState()
        // NSButton is flipped; CoreText expects a bottom-left coordinate system.
        if isFlipped { context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1) }
        context.textMatrix = .identity
        context.textPosition = layout.notchQOrigin(in: bounds)
        CTLineDraw(line, context)
        context.restoreGState()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    init() {
        panel = NotchQPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "NotchQ"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let backdrop = NotchQBadgeBackground(frame: NSRect(x: 0, y: 0, width: 58, height: 30))
        button = NotchQBadgeButton(frame: backdrop.bounds)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.focusRingType = .none
        button.autoresizingMask = [.width, .height]
        button.setAccessibilityLabel("Codex usage remaining")
        backdrop.addSubview(button)
        panel.contentView = backdrop
        button.target = self
        button.action = #selector(notchQBadgeClicked)
    }

    @discardableResult
    func notchQPositionBadge(show: Bool = true, animated: Bool = true) -> Bool {
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
        return true
    }

    func notchQUpdateBadge(title: NSAttributedString, indicatorCount: Int, tooltip: String) {
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
