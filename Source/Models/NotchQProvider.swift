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
        self == .codex ? .white : NSColor(srgbRed: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255, alpha: 1)
    }
    static func notchQRunning(in identifiers: Set<String>) -> [NotchQProvider] {
        allCases.filter { identifiers.contains($0.bundleIdentifier) }
    }
    static func notchQDisplayed(running: [NotchQProvider], codex: NotchQUsageState, claude: NotchQUsageState) -> [NotchQProvider] {
        running.filter { provider in
            let state = provider == .codex ? codex : claude
            return state.snapshot != nil && state.error == nil
        }
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
