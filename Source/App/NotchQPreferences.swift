import AppKit

enum NotchQPreferences {
    static let applicationIdentifier = "io.github.xentiles.NotchQ"
    static let legacyIdentifier = "local.dominik.codex-usage"
    static let refreshInterval: TimeInterval = 10
    static let claudeRefreshInterval: TimeInterval = 120
    static let claudeMaximumAge: TimeInterval = 180
    static var defaults: UserDefaults { .standard }
    static var codexEnabled: Bool { defaults.bool(forKey: "codexEnabled") }
    static var claudeEnabled: Bool { defaults.bool(forKey: "claudeEnabled") }
    static var onlyRunningApps: Bool { defaults.bool(forKey: "onlyRunningApps") }
    static var autoCheckUpdates: Bool { defaults.bool(forKey: "autoCheckUpdates") }
    static var preferNotch: Bool { defaults.bool(forKey: "preferNotchPosition") }
    /// Low-limit warnings: a limit with this many percent or fewer left blinks on the badge and is reminded once per reset.
    static let lowLimitThresholdKey = "lowLimitThreshold"
    static let defaultLowLimitThreshold = 10
    static let lowLimitThresholdChoices = [5, 10, 15, 20, 25]
    static var lowLimitThreshold: Int {
        let value = defaults.integer(forKey: lowLimitThresholdKey)
        return value <= 0 ? defaultLowLimitThreshold : min(50, value)
    }
    /// The card that drops from the notch when a limit gets low.
    static var reminderCardEnabled: Bool { defaults.bool(forKey: "lowLimitReminderCard") }
    /// The optional macOS notification sent alongside the card.
    static var reminderNotificationEnabled: Bool { defaults.bool(forKey: "lowLimitReminderNotification") }
    static func chosenCLIKey(_ provider: NotchQProvider) -> String { provider == .codex ? "codexCLIPath" : "claudeCLIPath" }
    static func chosenCLI(_ provider: NotchQProvider) -> String? { defaults.string(forKey: chosenCLIKey(provider)) }
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchQ", isDirectory: true)
    }
    static func notchQPrepareDefaults() {
        if defaults.object(forKey: "didMigrateLegacyPreferences") == nil {
            let legacy = defaults.persistentDomain(forName: legacyIdentifier) ?? [:]
            for key in ["preferNotchPosition", "codexEnabled", "claudeEnabled", "onlyRunningApps", "codexCLIPath"] {
                if defaults.object(forKey: key) == nil, let value = legacy[key] { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "didMigrateLegacyPreferences")
        }
        defaults.register(defaults: ["preferNotchPosition": true, "codexEnabled": true, "claudeEnabled": true, "onlyRunningApps": false, "autoCheckUpdates": true,
                                       lowLimitThresholdKey: defaultLowLimitThreshold, "lowLimitReminderCard": true, "lowLimitReminderNotification": false])
    }
}
