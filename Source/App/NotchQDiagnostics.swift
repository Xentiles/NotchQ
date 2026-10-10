import Foundation
import os

// Fixed event codes, reason codes and numeric measurements only; no terminal output, paths or authentication data.
// Events also go to the macOS unified log (subsystem = the app's bundle ID), so testers can share them with:
//   /usr/bin/log show --last 2h --style compact --predicate 'subsystem == "io.github.xentiles.NotchQ"'
// (the full path matters: in zsh, plain `log` is a shell built-in).
final class NotchQDiagnostics {
    static let shared = NotchQDiagnostics()
    enum Event: String {
        case requestStarted, succeeded, failed, snapshot, queued, stopped, sleeping, recovering, notch, menuBar, hidden
        case launched, paused, resumed, detected, updateChecked, updateAvailable, updateInstalling, updateFailed
    }
    /// Why something failed or changed. Stable values, safe to share.
    enum Reason: String {
        case timeout, throttled, signedOut, exited, disconnected, notFound, noLimits, incompatible, safetyStop, rejected
        case systemSleep, displaySleep, otherUser, wake, automatic, chosen, upToDate, signature, download, manualOnly
    }
    struct Entry { let time: Date; let event: Event; let provider: NotchQProvider?; let remaining: Int?; let seconds: Double?; let visible: Bool?; let onActiveSpace: Bool?; var reason: Reason? = nil; var detail: String? = nil }
    private(set) var entries: [Entry] = []
    private var lastOutcome: [NotchQProvider: Event] = [:]
    private let subsystem = Bundle.main.bundleIdentifier ?? NotchQPreferences.applicationIdentifier
    private lazy var loggers: [String: Logger] = [:]

    /// Maps NotchQ's fixed user-facing messages to reason codes (messages never contain raw provider output).
    static func notchQReason(for message: String) -> Reason {
        let text = message.lowercased()
        // Order matters: several messages also suggest signing in, so specific causes come first.
        if text.contains("no usage limits") { return .noLimits }
        if text.contains("throttled") || text.contains("rate limiting") { return .throttled }
        if text.contains("timed out") { return .timeout }
        if text.contains("closed unexpectedly") { return .exited }
        if text.contains("connection closed") { return .disconnected }
        if text.contains("unavailable") || text.contains("not found") { return .notFound }
        if text.contains("model activity") { return .safetyStop }
        if text.contains("not empty") || text.contains("incompatible") { return .incompatible }
        if text.contains("sign in") { return .signedOut }
        return .rejected
    }

    func record(_ event: Event, provider: NotchQProvider? = nil, remaining: Int? = nil, seconds: Double? = nil, visible: Bool? = nil, onActiveSpace: Bool? = nil, reason: Reason? = nil, detail: String? = nil) {
        entries.append(Entry(time: Date(), event: event, provider: provider, remaining: remaining, seconds: seconds, visible: visible, onActiveSpace: onActiveSpace, reason: reason, detail: detail))
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
        let line = "event=\(event.rawValue) provider=\(provider?.rawValue ?? "app")" + (reason.map { " reason=\($0.rawValue)" } ?? "")
            + (detail.map { " detail=\($0)" } ?? "") + (remaining.map { (event == .failed ? " lastKnown=" : " remaining=") + "\($0)%" } ?? "")
            + (seconds.map { String(format: " seconds=%.2f", $0) } ?? "") + (visible.map { " visible=\($0)" } ?? "")
        notchQLog(event, provider: provider, line)
        if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
            print("NotchQ time=\(Date().timeIntervalSince1970) \(line) onActiveSpace=\(onActiveSpace.map { String($0) } ?? "unknown")")
            fflush(stdout)
        }
    }

    /// Persisted (notice/error): failures, state changes and the first success after launch or a failure.
    /// Routine events are info/debug, which macOS keeps only briefly in memory, so logs stay small.
    private func notchQLog(_ event: Event, provider: NotchQProvider?, _ line: String) {
        let category: String
        switch event {
        case .notch, .menuBar, .hidden, .recovering: category = "display"
        case .launched, .paused, .resumed, .sleeping: category = "lifecycle"
        case .updateChecked, .updateAvailable, .updateInstalling, .updateFailed: category = "update"
        case .detected: category = "detection"
        default: category = provider?.rawValue ?? "app"
        }
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category)
        loggers[category] = logger
        switch event {
        case .failed, .updateFailed:
            logger.error("\(line, privacy: .public)")
        case .succeeded, .snapshot:
            let previous = provider.flatMap { lastOutcome[$0] }
            if previous != .succeeded && previous != .snapshot { logger.notice("\(line, privacy: .public)") } else { logger.info("\(line, privacy: .public)") }
        case .launched, .paused, .resumed, .sleeping, .detected, .updateChecked, .updateAvailable, .updateInstalling:
            logger.notice("\(line, privacy: .public)")
        case .notch, .menuBar, .hidden, .recovering:
            logger.info("\(line, privacy: .public)")
        case .requestStarted, .queued, .stopped:
            logger.debug("\(line, privacy: .public)")
        }
        if let provider = provider, [.succeeded, .snapshot, .failed].contains(event) { lastOutcome[provider] = event }
    }
}
