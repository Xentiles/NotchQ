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
        if minutes == 43200 { return "Monthly" }   // e.g. Codex without a subscription
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

/// A limit that is nearly used up, by class, so every plan and tier behaves the same way. Each class blinks with
/// its own rhythm and gets its own reminder (once per period).
/// - `.fiveHour`: the short-window class, any window shorter than a week (5-hour, 1-hour, …) or of unknown
///   length: the soft pulse.
/// - `.weekly`: the long-window class, any window of a week or longer (weekly, monthly, …): the sharp double
///   pulse, and it takes over the badge.
/// The raw values are kept as the reminder IDs and preference keys they always were.
enum NotchQLowLimit: String, CaseIterable {
    case fiveHour, weekly
    static let fiveHourMinutes = 300, weeklyMinutes = 10080
    /// The class a window belongs to, whatever its figure.
    static func notchQClass(_ window: NotchQUsageWindow) -> NotchQLowLimit {
        (window.minutes ?? 0) >= weeklyMinutes ? .weekly : .fiveHour
    }
    /// The low limit a window stands for, if it is at or below `threshold` percent left.
    init?(_ window: NotchQUsageWindow, threshold: Int) {
        guard window.remaining <= threshold else { return nil }
        self = Self.notchQClass(window)
    }
}

extension NotchQUsageWindow {
    /// How the window is named in sentences: "weekly", "monthly", "5-hour", "1-hour"; "usage" when its length is unknown.
    var spokenName: String { minutes == nil ? "usage" : label.lowercased() }
}

struct NotchQUsageSnapshot {
    let windows: [NotchQUsageWindow]
    var remaining: Int { windows.map(\.remaining).min()! }
    /// The window of a class at or below the threshold with the least left, if any.
    func notchQLowWindow(_ limit: NotchQLowLimit, threshold: Int = NotchQPreferences.lowLimitThreshold) -> NotchQUsageWindow? {
        windows.filter { NotchQLowLimit($0, threshold: threshold) == limit }.min { $0.remaining < $1.remaining }
    }
    /// At or below the low-limit threshold (Settings; 10% by default), a long limit (weekly, monthly, …) is the
    /// one about to stop the user, so it takes over the badge. If a short limit is low too, the long one still wins.
    func notchQWeeklyNearlyExhausted(threshold: Int = NotchQPreferences.lowLimitThreshold) -> Bool {
        notchQLowWindow(.weekly, threshold: threshold) != nil
    }
    var weeklyNearlyExhausted: Bool { notchQWeeklyNearlyExhausted() }
    /// The window the badge shows: the low long window with the least left; otherwise the low short window with the
    /// least left; otherwise the 5-hour one, then the weekly one, then whichever has the least left (so a plan with
    /// only a monthly window shows that).
    func notchQDisplayWindow(threshold: Int = NotchQPreferences.lowLimitThreshold) -> NotchQUsageWindow? {
        if let long = notchQLowWindow(.weekly, threshold: threshold) { return long }
        if let short = notchQLowWindow(.fiveHour, threshold: threshold) { return short }
        return windows.first { $0.minutes == NotchQLowLimit.fiveHourMinutes } ?? windows.first { $0.minutes == NotchQLowLimit.weeklyMinutes }
            ?? windows.min { $0.remaining < $1.remaining }
    }
    var displayWindow: NotchQUsageWindow? { notchQDisplayWindow() }
    /// For each class, the low window with the least left, whether or not it is the one on the badge
    /// (each class gets its own reminder).
    func notchQLowWindows(threshold: Int = NotchQPreferences.lowLimitThreshold) -> [(limit: NotchQLowLimit, window: NotchQUsageWindow)] {
        NotchQLowLimit.allCases.compactMap { limit in notchQLowWindow(limit, threshold: threshold).map { (limit: limit, window: $0) } }
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
    /// The badge figure is a nearly used-up limit: which one, so it blinks with that limit's rhythm.
    /// `nil` while no current figure is on the badge.
    func notchQLowLimit(threshold: Int = NotchQPreferences.lowLimitThreshold) -> NotchQLowLimit? {
        guard error == nil || holding, let window = snapshot?.notchQDisplayWindow(threshold: threshold) else { return nil }
        return NotchQLowLimit(window, threshold: threshold)
    }
    var lowLimit: NotchQLowLimit? { notchQLowLimit() }
    var pulsing: Bool { lowLimit != nil }
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
