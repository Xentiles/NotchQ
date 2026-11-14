import AppKit

enum NotchQProvider: String, CaseIterable {
    case codex, claude
    var bundleIdentifier: String {
        switch self {
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        }
    }
    var displayName: String { self == .codex ? "Codex" : "Claude" }
    var color: NSColor {
        self == .codex ? NSColor(srgbRed: 240.0 / 255, green: 240.0 / 255, blue: 240.0 / 255, alpha: 1)
            : NSColor(srgbRed: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255, alpha: 1)
    }
    static func notchQRunning(in identifiers: Set<String>) -> [NotchQProvider] {
        allCases.filter { identifiers.contains($0.bundleIdentifier) }
    }
}

func notchQProviderTitle(_ providers: [NotchQProvider], codex: String, claude: String = "—%", onBlack: Bool = true) -> NSAttributedString {
    let title = NSMutableAttributedString(string: "")
    for (index, provider) in providers.enumerated() {
        if index > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 14)])) }
        let color = provider == .codex && !onBlack ? NSColor.labelColor : provider.color
        title.append(notchQPercentageTitle(provider == .codex ? codex : claude, color: color))
    }
    return title
}

/// Where each provider's figure sits in the title built by `notchQProviderTitle` (two spaces between figures).
func notchQProviderRanges(_ providers: [NotchQProvider], codex: String, claude: String = "—%") -> [NotchQProvider: NSRange] {
    var ranges: [NotchQProvider: NSRange] = [:], location = 0
    for (index, provider) in providers.enumerated() {
        if index > 0 { location += 2 }
        let length = ((provider == .codex ? codex : claude) as NSString).length
        ranges[provider] = NSRange(location: location, length: length); location += length
    }
    return ranges
}

/// The same title with some figures made transparent. Layout is untouched (colour does not move glyphs),
/// so a title drawn with `keep: false` and one drawn with `keep: true` on top of it line up exactly.
/// - keep == false: the given ranges are hidden. - keep == true: only the given ranges stay visible.
func notchQMaskedTitle(_ title: NSAttributedString, ranges: [NSRange], keep: Bool) -> NSAttributedString {
    let text = NSMutableAttributedString(attributedString: title), full = NSRange(location: 0, length: text.length)
    if keep { text.addAttribute(.foregroundColor, value: NSColor.clear, range: full) }
    for range in ranges.map({ NSIntersectionRange($0, full) }) where range.length > 0 {
        if keep {
            title.enumerateAttribute(.foregroundColor, in: range) { color, part, _ in
                text.addAttribute(.foregroundColor, value: color ?? NSColor.labelColor, range: part)
            }
        } else { text.addAttribute(.foregroundColor, value: NSColor.clear, range: range) }
    }
    return text
}
