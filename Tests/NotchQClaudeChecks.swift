import Foundation

func runNotchQClaudeChecks() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchq-claude-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("settings.json")
    let connection = NotchQClaudeConnection(directory: directory.appendingPathComponent("cache"), configuration: config)
    let now = Date(timeIntervalSince1970: 2000)
    var payload: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": 30.4, "resets_at": 5000], "seven_day": ["used_percentage": 80, "resets_at": 9000]], "cost": ["total_api_duration_ms": 10], "cwd": "/private/workspace", "session_id": "private"]
    let reading = try! connection.notchQIngest(payload, now: now)
    precondition(reading.snapshot.remaining == 20)
    let duplicate = try! connection.notchQIngest(payload, now: now.addingTimeInterval(10))
    precondition(duplicate.observedAt == now, "timer repeat does not fake freshness")
    precondition(connection.notchQCachedReading(now: now.addingTimeInterval(181)) == nil)
    payload["cost"] = ["total_api_duration_ms": 11]
    precondition(try! connection.notchQIngest(payload, now: now.addingTimeInterval(20)).observedAt == now.addingTimeInterval(20))
    let bytes = try! Data(contentsOf: connection.cacheURL)
    let text = String(data: bytes, encoding: .utf8)!
    precondition(!text.contains("private/workspace") && !text.contains("session_id"), "cache contains no workspace or session identity")
    let mode = try! FileManager.default.attributesOfItem(atPath: connection.cacheURL.path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o600)
    do { _ = try connection.notchQIngest([:]); preconditionFailure("missing limits accepted") } catch {}
    precondition(connection.notchQCachedReading(maximumAge: .infinity, now: now) == nil)
    let original: [String: Any] = ["statusLine": ["type": "command", "command": "printf old", "padding": 2], "other": true]
    try! JSONSerialization.data(withJSONObject: original).write(to: config)
    try! connection.notchQConnect(executable: URL(fileURLWithPath: "/Applications/NotchQ.app/Contents/MacOS/NotchQ"))
    precondition(connection.isConnected && connection.notchQOriginalStatusCommand() == "printf old")
    try! connection.notchQDisconnect()
    let restored = try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    precondition((restored["statusLine"] as! [String: Any])["command"] as! String == "printf old" && restored["other"] as! Bool)
    try! connection.notchQConnect(executable: URL(fileURLWithPath: "/Applications/NotchQ.app/Contents/MacOS/NotchQ"))
    var changed = try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    changed["statusLine"] = ["type": "command", "command": "new user choice"]
    try! JSONSerialization.data(withJSONObject: changed).write(to: config)
    do { try connection.notchQDisconnect(); preconditionFailure("overwrote user change") } catch {}
    print("Passed Claude connection checks: percentages, freshness, minimization, permissions, backup/restore and conflict preservation")
}
