import Foundation

/// Unparsed reset text keeps its zone label only when it differs from the viewer's own zone.
func notchQLocalResetText(_ text: String, timeZone: TimeZone) -> String {
    let suffix = " (\(timeZone.identifier))"
    return text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text
}

func notchQUsageMenuRows(_ state: NotchQUsageState, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
    var rows: [String] = []
    if let error = state.error { rows.append(error) }
    let windows = (state.snapshot?.windows ?? []).enumerated().sorted {
        let left = $0.element.minutes ?? Int.max
        let right = $1.element.minutes ?? Int.max
        return left == right ? $0.offset < $1.offset : left < right
    }.map(\.element)
    let prefix = state.error == nil ? "" : "Last known "
    rows += windows.map { "\(prefix)\($0.label): \($0.remaining)% left" }
    let resetFormat = DateFormatter()
    resetFormat.dateStyle = .medium; resetFormat.timeStyle = .short; resetFormat.timeZone = timeZone
    for window in windows {
        let reset = window.reset.map { resetFormat.string(from: $0) } ?? window.resetDescription.map { notchQLocalResetText($0, timeZone: timeZone) } ?? "unavailable"
        rows.append("\(prefix)\(window.label) resets: \(reset)")
    }
    if let updated = state.updated {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX"); time.timeZone = timeZone; time.dateFormat = "HH:mm:ss"
        let suffix = state.error == nil ? "" : " (last successful check)"
        rows.append("Last updated: \(time.string(from: updated))\(suffix)")
    }
    if now < state.nextAllowed {
        rows.append("Retry in \(Int(ceil(state.nextAllowed.timeIntervalSince(now)))) seconds")
    }
    return rows
}
