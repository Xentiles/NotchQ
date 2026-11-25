import Foundation

/// Unparsed reset text keeps its zone label only when it differs from the viewer's own zone.
func notchQLocalResetText(_ text: String, timeZone: TimeZone) -> String {
    let suffix = " (\(timeZone.identifier))"
    return text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text
}

/// "35 s", "2 min 05 s", "1 h 54 min", "5 d 3 h": compact, and it visibly ticks while the menu is open.
func notchQDurationText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3600 { return String(format: "%d min %02d s", seconds / 60, seconds % 60) }
    if seconds < 86_400 { return "\(seconds / 3600) h \(seconds % 3600 / 60) min" }
    return "\(seconds / 86_400) d \(seconds % 86_400 / 3600) h"
}

func notchQUsageMenuRows(_ state: NotchQUsageState, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
    var rows: [String] = []
    if let error = state.error { rows.append(error) }
    let windows = (state.snapshot?.windows ?? []).enumerated().sorted {
        let left = $0.element.minutes ?? Int.max
        let right = $1.element.minutes ?? Int.max
        return left == right ? $0.offset < $1.offset : left < right
    }.map(\.element)
    let prefix = state.error == nil || state.holding ? "" : "Last known "
    // Any window at or below the warning threshold is marked, and so is the one on the badge (a long window such as
    // weekly or monthly wins when several are low). Last-known figures are not marked: they are not on the badge.
    let threshold = NotchQPreferences.lowLimitThreshold, shown = state.snapshot?.notchQDisplayWindow(threshold: threshold)
    rows += windows.map { window in
        let low = prefix.isEmpty && NotchQLowLimit(window, threshold: threshold) != nil
        return "\(prefix)\(window.label): \(window.remaining)% left" + (low ? " — nearly used up" + (window.minutes == shown?.minutes ? "; shown on the badge" : "") : "")
    }
    let resetFormat = DateFormatter()
    resetFormat.dateStyle = .medium; resetFormat.timeStyle = .short; resetFormat.timeZone = timeZone
    for window in windows {
        let reset = window.reset.map { resetFormat.string(from: $0) } ?? window.resetDescription.map { notchQLocalResetText($0, timeZone: timeZone) } ?? "unavailable"
        let countdown = window.reset.flatMap { $0 > now ? " (in \(notchQDurationText($0.timeIntervalSince(now))))" : nil } ?? ""
        rows.append("\(prefix)\(window.label) resets: \(reset)\(countdown)")
    }
    if let updated = state.updated {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX"); time.timeZone = timeZone; time.dateFormat = "HH:mm:ss"
        let suffix = state.error == nil ? "" : " (last successful check)"
        rows.append("Last updated: \(time.string(from: updated)) (\(notchQDurationText(now.timeIntervalSince(updated))) ago)\(suffix)")
    }
    if now < state.nextAllowed {
        let seconds = Int(ceil(state.nextAllowed.timeIntervalSince(now)))
        rows.append(state.error == nil ? "Next check in \(seconds) seconds" : "Retry in \(seconds) seconds")
    }
    return rows
}
