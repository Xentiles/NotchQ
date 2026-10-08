import Foundation
import CoreFoundation

struct NotchQUsageWindow {
    let remaining: Int
    let minutes: Int?
    let reset: Date?
    var label: String {
        guard let minutes = minutes else { return "Allowance" }
        if minutes == 10080 { return "Weekly" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

struct NotchQUsageSnapshot {
    let windows: [NotchQUsageWindow]
    var remaining: Int { windows.map(\.remaining).min()! }
    static func notchQParseCodexLimits(_ result: [String: Any]) -> NotchQUsageSnapshot? {
        let grouped = result["rateLimitsByLimitId"] as? [String: Any]
        let limits = grouped?["codex"] as? [String: Any] ?? result["rateLimits"] as? [String: Any]
        guard let limits = limits, (limits["limitId"] as? String ?? "codex") == "codex" else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> NotchQUsageWindow? in
            guard let value = limits[key] as? [String: Any],
                  let used = value["usedPercent"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite else { return nil }
            let remaining = Int(floor(min(100, max(0, 100 - used.doubleValue))))
            let duration = (value["windowDurationMins"] as? NSNumber)?.intValue
            let reset = (value["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return NotchQUsageWindow(remaining: remaining, minutes: duration, reset: reset)
        }
        return windows.isEmpty ? nil : NotchQUsageSnapshot(windows: windows)
    }
}

struct NotchQUsageState {
    var snapshot: NotchQUsageSnapshot?
    var updated: Date?
    var error: String?
    var failures = 0
    var nextAllowed = Date.distantPast
    var percentage: String { error == nil ? snapshot.map { "\($0.remaining)%" } ?? "—%" : "—%" }
    mutating func notchQRecordSuccess(_ value: NotchQUsageSnapshot, now: Date = Date()) {
        snapshot = value; updated = now; error = nil; failures = 0; nextAllowed = .distantPast
    }
    mutating func notchQRecordFailure(_ message: String, now: Date = Date(), retryAfter: Double? = nil) {
        error = message; failures += 1
        let delay = min(300, 10 * pow(2, Double(min(failures - 1, 5))))
        nextAllowed = now.addingTimeInterval(max(delay, retryAfter ?? 0))
    }
}
