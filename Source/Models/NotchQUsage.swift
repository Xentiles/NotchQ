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
    /// Below this many percent left, the weekly limit is the one about to stop the user, so it takes
    /// over the badge from the 5-hour figure (and the figure pulses).
    static let weeklyTakeoverBelow = 5
    var weeklyNearlyExhausted: Bool { windows.contains { $0.minutes == 10080 && $0.remaining < Self.weeklyTakeoverBelow } }
    /// The window the badge shows: the 5-hour one, unless the weekly one is nearly used up.
    var displayWindow: NotchQUsageWindow? {
        if weeklyNearlyExhausted, let weekly = windows.first(where: { $0.minutes == 10080 }) { return weekly }
        return windows.first { $0.minutes == 300 } ?? windows.first { $0.minutes == 10080 }
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

extension NotchQUsageSnapshot {
    /// Two reset times this close describe the same window period (sources round the time differently).
    static let samePeriodTolerance: TimeInterval = 120
    static let roundingSlack = 2
    /// Windows whose reset time has not passed; `nil` when none is left. A window past its reset is no longer current.
    func notchQUnexpired(now: Date = Date()) -> NotchQUsageSnapshot? {
        let live = windows.filter { $0.reset.map { $0 > now } ?? true }
        return live.isEmpty ? nil : NotchQUsageSnapshot(windows: live)
    }
    /// Combines a newer observation with what is displayed, window by window, so two sources that round
    /// differently (/usage: whole percent; status line: decimals) cannot make the badge step back up.
    /// - Same period (reset times within `samePeriodTolerance`): the newer figure wins, but remaining does not
    ///   step up by a rounding-sized amount (`roundingSlack`). A larger rise is a real change and is shown.
    /// - Different or unknown period: the newer figure is taken as is.
    /// - A displayed window the newer observation lacks is kept until its reset time passes.
    static func notchQMerged(current: NotchQUsageSnapshot?, incoming: NotchQUsageSnapshot, now: Date = Date()) -> NotchQUsageSnapshot? {
        let previous = current?.notchQUnexpired(now: now)?.windows ?? []
        var windows = (incoming.notchQUnexpired(now: now)?.windows ?? []).map { window -> NotchQUsageWindow in
            guard let old = previous.first(where: { $0.minutes == window.minutes }), let oldReset = old.reset, let reset = window.reset,
                  abs(reset.timeIntervalSince(oldReset)) <= samePeriodTolerance, old.remaining < window.remaining, window.remaining - old.remaining <= roundingSlack else { return window }
            return NotchQUsageWindow(remaining: old.remaining, minutes: window.minutes, reset: window.reset, resetDescription: window.resetDescription)
        }
        // Without a reset time there is no way to know when a carried-over window stops being current.
        windows += previous.filter { old in old.reset != nil && !windows.contains { $0.minutes == old.minutes } }
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
    /// The badge figure is a weekly limit that is nearly used up; it pulses while this holds.
    var pulsing: Bool { (error == nil || holding) && (snapshot?.weeklyNearlyExhausted ?? false) }
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
