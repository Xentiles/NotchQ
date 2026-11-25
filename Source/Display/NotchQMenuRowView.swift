import AppKit

/// The dropdown's coloured information rows: the "NotchQ" title, each provider's heading, and its current figures
/// and reset times.
///
/// AppKit dims a disabled menu item's attributed title, so a coloured title on an info row never reaches the
/// screen at full strength. These rows are custom item views instead: they draw their text in exactly the colour
/// given, in the menu font, aligned with the standard rows, and (like any view row) do not highlight on hover,
/// which suits information that is not clickable. Faded rows stay ordinary disabled items.
final class NotchQMenuRowView: NSView {
    var text: String { didSet { if text != oldValue { notchQTextChanged() } } }
    var color: NSColor { didSet { needsDisplay = true } }
    /// Where the text starts, matching a standard row's title (more when the menu shows a checkmark column).
    var leftInset: CGFloat { didSet { if leftInset != oldValue { notchQTextChanged() } } }
    static var font: NSFont { .menuFont(ofSize: 0) }

    init(text: String, color: NSColor, leftInset: CGFloat = NotchQMenuGeometry.shared.textInset(stateColumn: false)) {
        self.text = text; self.color = color; self.leftInset = leftInset
        super.init(frame: .zero)
        autoresizingMask = .width
        notchQTextChanged()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // Exact colour: no blending with the menu's translucent material.
    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }

    private var attributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: color] }
    private func notchQTextChanged() {
        let geometry = NotchQMenuGeometry.shared
        let width = ceil(leftInset + (text as NSString).size(withAttributes: [.font: Self.font]).width + geometry.trailingPadding)
        setFrameSize(NSSize(width: max(frame.width, width), height: geometry.rowHeight))
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityValue(text); setAccessibilityLabel(text)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        // Drawing runs with the menu's appearance current, so dynamic colours resolve to the dark or light variant.
        let font = Self.font
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        (text as NSString).draw(at: NSPoint(x: leftInset, y: floor((bounds.height - lineHeight) / 2)), withAttributes: attributes)
    }
}

/// Standard menu-row measurements on this Mac, read once from AppKit's own layout (NSMenu.size) rather than
/// assumed, so view rows line up with ordinary rows on any macOS version.
struct NotchQMenuGeometry {
    static let shared = NotchQMenuGeometry()
    let rowHeight: CGFloat
    /// Horizontal padding around a standard title (split evenly between the two sides), and the checkmark column.
    let leadingPadding: CGFloat, trailingPadding: CGFloat, stateColumn: CGFloat

    init() {
        let probe = "Xxxxxxxxxxxxxxxxxxxx", textWidth = (probe as NSString).size(withAttributes: [.font: NotchQMenuRowView.font]).width
        func size(rows: Int, checked: Bool) -> NSSize {
            let menu = NSMenu()
            for index in 0..<rows { let item = NSMenuItem(title: probe, action: nil, keyEquivalent: ""); if checked && index == 0 { item.state = .on }; menu.addItem(item) }
            return menu.size
        }
        let one = size(rows: 1, checked: false), two = size(rows: 2, checked: false), checked = size(rows: 1, checked: true)
        rowHeight = max(16, two.height - one.height)
        let padding = max(0, one.width - textWidth)
        leadingPadding = (padding / 2).rounded(); trailingPadding = padding - leadingPadding
        stateColumn = max(0, checked.width - one.width)
    }
    func textInset(stateColumn shown: Bool) -> CGFloat { leadingPadding + (shown ? stateColumn : 0) }
    /// AppKit reserves the checkmark column only when some item is on or mixed.
    static func notchQShowsStateColumn(_ menu: NSMenu) -> Bool { menu.items.contains { $0.state != .off } }
}

/// The dropdown's colours. All opaque, so nothing behind the menu shifts them; the title and Codex follow the
/// menu's appearance.
enum NotchQMenuPalette {
    static func notchQIsDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    /// "NotchQ": pure white in a dark menu, pure black in a light one.
    static let title = NSColor(name: "NotchQMenuTitle") { notchQIsDark($0) ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) }
    /// Codex: an opaque light grey (0.80 in a dark menu, mirrored to 0.20 in a light one). Measured on screen it sits
    /// about a third of the way from the clickable items' text down to the faded info rows: clearly brighter than
    /// those, visibly less white than Settings… or Quit, and weighted like Claude's dimmed orange.
    static let codexLevel: CGFloat = 0.80
    static let codex = NSColor(name: "NotchQMenuCodex") { notchQIsDark($0) ? NSColor(srgbRed: codexLevel, green: codexLevel, blue: codexLevel, alpha: 1) : NSColor(srgbRed: 1 - codexLevel, green: 1 - codexLevel, blue: 1 - codexLevel, alpha: 1) }
    /// Claude: the badge orange (217, 119, 87) with the same hue and saturation and HSB brightness × 0.92, opaque:
    /// it reads like the badge colour at 92% without mixing with the menu background. One colour suits both
    /// appearances; the slight dimming also helps it on a light menu.
    static let claudeBrightness: CGFloat = 0.92
    static let claude = NSColor(srgbRed: 217 * claudeBrightness / 255, green: 119 * claudeBrightness / 255, blue: 87 * claudeBrightness / 255, alpha: 1)
}
