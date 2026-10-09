import Foundation

// Fixed event codes and numeric measurements only; no terminal output or authentication data.
final class NotchQDiagnostics {
    static let shared = NotchQDiagnostics()
    enum Event: String { case requestStarted, succeeded, failed, snapshot, queued, stopped, sleeping, recovering, notch, menuBar, hidden }
    struct Entry { let time: Date; let event: Event; let provider: NotchQProvider?; let remaining: Int?; let seconds: Double?; let visible: Bool?; let onActiveSpace: Bool? }
    private(set) var entries: [Entry] = []
    func record(_ event: Event, provider: NotchQProvider? = nil, remaining: Int? = nil, seconds: Double? = nil, visible: Bool? = nil, onActiveSpace: Bool? = nil) {
        entries.append(Entry(time: Date(), event: event, provider: provider, remaining: remaining, seconds: seconds, visible: visible, onActiveSpace: onActiveSpace))
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
        if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
            print("NotchQ time=\(Date().timeIntervalSince1970) event=\(event.rawValue) provider=\(provider?.rawValue ?? "display") remaining=\(remaining.map(String.init) ?? "unknown") seconds=\(seconds.map { String(format: "%.3f", $0) } ?? "unknown") visible=\(visible.map { String($0) } ?? "unknown") onActiveSpace=\(onActiveSpace.map { String($0) } ?? "unknown")")
            fflush(stdout)
        }
    }
}
