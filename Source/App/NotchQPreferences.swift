import AppKit

enum NotchQPreferences {
    static let applicationIdentifier = "io.github.xentiles.NotchQ"
    static let legacyIdentifier = "local.dominik.codex-usage"
    static let refreshInterval: TimeInterval = 10
    static let claudeMaximumAge: TimeInterval = 180
    static var defaults: UserDefaults { .standard }
    static var codexEnabled: Bool { defaults.bool(forKey: "codexEnabled") }
    static var claudeEnabled: Bool { defaults.bool(forKey: "claudeEnabled") }
    static var onlyRunningApps: Bool { defaults.bool(forKey: "onlyRunningApps") }
    static var preferNotch: Bool { defaults.bool(forKey: "preferNotchPosition") }
    static var codexCLI: String? { defaults.string(forKey: "codexCLIPath") }
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
        defaults.register(defaults: ["preferNotchPosition": true, "codexEnabled": true, "claudeEnabled": true, "onlyRunningApps": true])
    }
}
