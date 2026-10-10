import Foundation
import CoreFoundation

struct NotchQUsageWindow {
    let remaining: Int
    let minutes: Int?
    let reset: Date?
    var resetDescription: String? = nil
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
    var displayWindow: NotchQUsageWindow? {
        windows.first { $0.minutes == 300 } ?? windows.first { $0.minutes == 10080 }
            ?? windows.min { $0.remaining < $1.remaining }
    }
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

/// Claude's usage service rate-limits frequent /usage checks (a 4-hour run at 60 s was throttled about
/// every 5 minutes), so Claude polls every 2 minutes, doubles its wait after each throttle (up to a cap),
/// and only steps back down one level after `stepDownAfter` successful reads in a row.
struct NotchQPollCadence {
    let base: TimeInterval
    let maximum: TimeInterval
    var stepDownAfter = 5
    private(set) var level = 0
    private var cleanReads = 0
    var interval: TimeInterval { min(maximum, base * pow(2, Double(level))) }
    mutating func notchQThrottled() -> TimeInterval { level = min(level + 1, 4); cleanReads = 0; return interval }
    mutating func notchQSucceeded() -> TimeInterval {
        cleanReads += 1
        if level > 0 && cleanReads >= stepDownAfter { level -= 1; cleanReads = 0 }
        return interval
    }
}

struct NotchQUsageState {
    var snapshot: NotchQUsageSnapshot?
    var updated: Date?
    var error: String?
    var failures = 0
    var nextAllowed = Date.distantPast
    var throttledUntil = Date.distantPast
    /// During a short rate limit the last reading stays on the badge until this time (then "—%").
    var holdUntil: Date?
    var holding: Bool { error != nil && snapshot != nil && (holdUntil.map { Date() < $0 } ?? false) }
    var percentage: String { error == nil || holding ? snapshot?.displayWindow.map { "\($0.remaining)%" } ?? "—%" : "—%" }
    mutating func notchQPrepareManualRefresh() { nextAllowed = throttledUntil }
    mutating func notchQRecordSuccess(_ value: NotchQUsageSnapshot, now: Date = Date()) {
        snapshot = value; updated = now; error = nil; failures = 0; nextAllowed = .distantPast; throttledUntil = .distantPast; holdUntil = nil
    }
    mutating func notchQRecordFailure(_ message: String, now: Date = Date(), retryAfter: Double? = nil) {
        error = message; failures += 1; holdUntil = nil
        let delay = min(300, 10 * pow(2, Double(min(failures - 1, 5))))
        if let retry = retryAfter, retry.isFinite, retry > 0 { throttledUntil = now.addingTimeInterval(retry) }
        nextAllowed = max(now.addingTimeInterval(delay), throttledUntil)
    }
}
