import AppKit
import CryptoKit

func runNotchQUpdaterChecks() {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("notchq-updater-" + UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    try! files.createDirectory(at: root, withIntermediateDirectories: true)

    // Versions: Bv tags only, compared numerically.
    precondition(NotchQVersion(tag: "Bv0.10.0")! > NotchQVersion(tag: "Bv0.9.9")! && NotchQVersion(tag: "Bv1.0.0")! > NotchQVersion(tag: "Bv0.99.99")!, "numeric version order")
    precondition(["v1.0.0", "Bv1.0", "Bv1.0.0-beta", "Bv-1.0.0", "Bv1..0", "BV1.0.0"].allSatisfy { NotchQVersion(tag: $0) == nil }, "only Bv<major>.<minor>.<patch> tags are releases")
    precondition(NotchQVersion("0.3.0")!.description == "Bv0.3.0" && NotchQVersion(tag: "Bv0.3.0") == NotchQVersion("0.3.0"), "bundle and tag versions agree")

    // A signed update archive made from a copy of this (test) app, which reports version 0.3.0.
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let source = root.appendingPathComponent("source/NotchQ.app")
    try! files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    precondition(NotchQUpdateVerifier.notchQRun("/usr/bin/ditto", [Bundle.main.bundlePath, source.path]) == 0)
    let version = NotchQVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String)!
    let older = NotchQVersion("0.0.1")!
    let archive = root.appendingPathComponent("NotchQ-\(version).zip")
    precondition(NotchQUpdateVerifier.notchQRun("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, archive.path]) == 0)
    let bytes = try! Data(contentsOf: archive)
    try! (try! key.signature(for: bytes)).base64EncodedString().write(to: archive.appendingPathExtension("sig"), atomically: true, encoding: .utf8)
    let signature = try! Data(contentsOf: archive.appendingPathExtension("sig"))

    // Signatures: only the exact archive, signed by the matching key, passes.
    precondition(NotchQUpdateVerifier.notchQSignatureValid(bytes, signature: signature, publicKey: publicKey), "valid signature accepted")
    var tampered = bytes; tampered[tampered.count / 2] ^= 0xFF
    precondition(!NotchQUpdateVerifier.notchQSignatureValid(tampered, signature: signature, publicKey: publicKey), "tampered archive rejected")
    let stranger = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    precondition(!NotchQUpdateVerifier.notchQSignatureValid(bytes, signature: signature, publicKey: stranger), "signature from another key rejected")
    precondition(!NotchQUpdateVerifier.notchQSignatureValid(bytes, signature: Data(), publicKey: publicKey) && !NotchQUpdateVerifier.notchQSignatureValid(bytes, signature: signature, publicKey: ""), "missing signature or key rejected")

    // Feed: newest non-draft Bv release above the current version, with both assets.
    func notchQRelease(_ tag: String, draft: Bool = false, archive: String? = nil, signature: String? = nil) -> [String: Any] {
        var assets: [[String: Any]] = []
        if let archive = archive { assets.append(["name": "NotchQ-\(tag).zip", "browser_download_url": archive]) }
        if let signature = signature { assets.append(["name": "NotchQ-\(tag).zip.sig", "browser_download_url": signature]) }
        return ["tag_name": tag, "draft": draft, "prerelease": true, "html_url": "https://github.com/Xentiles/NotchQ/releases/tag/\(tag)", "assets": assets]
    }
    let archiveURL = archive.absoluteString, signatureURL = archive.appendingPathExtension("sig").absoluteString
    let feed = try! JSONSerialization.data(withJSONObject: [
        notchQRelease("Bv9.0.0", draft: true, archive: archiveURL, signature: signatureURL),
        notchQRelease("Bv8.0.0", archive: archiveURL),
        notchQRelease("Bv7.0.0", archive: "http://example.com/a.zip", signature: "http://example.com/a.zip.sig"),
        notchQRelease("v6.0.0", archive: archiveURL, signature: signatureURL),
        notchQRelease(version.description, archive: archiveURL, signature: signatureURL),
        notchQRelease("Bv0.0.1", archive: archiveURL, signature: signatureURL)])
    precondition(NotchQRelease.notchQNewest(in: feed, above: older)?.version == version, "drafts, unsigned, insecure and non-Bv releases are skipped")
    precondition(NotchQRelease.notchQNewest(in: feed, above: version) == nil && NotchQRelease.notchQNewest(in: Data("{}".utf8), above: older) == nil, "up to date and malformed feeds offer nothing")

    // Staged bundle checks.
    let identifier = Bundle.main.bundleIdentifier!
    precondition(NotchQUpdateVerifier.notchQProblem(with: source, expected: version, current: older, bundleIdentifier: identifier) == nil, "genuine newer build accepted")
    precondition(NotchQUpdateVerifier.notchQProblem(with: source, expected: version, current: older, bundleIdentifier: "com.example.other") != nil, "other app rejected")
    precondition(NotchQUpdateVerifier.notchQProblem(with: source, expected: version, current: version, bundleIdentifier: identifier) != nil, "same version is not an update")
    precondition(NotchQUpdateVerifier.notchQProblem(with: source, expected: NotchQVersion("9.9.9")!, current: older, bundleIdentifier: identifier) != nil, "version must match the release")
    let broken = root.appendingPathComponent("broken/NotchQ.app")
    try! files.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
    precondition(NotchQUpdateVerifier.notchQRun("/usr/bin/ditto", [source.path, broken.path]) == 0)
    try! Data("tampered".utf8).write(to: broken.appendingPathComponent("Contents/Resources/Libron-LICENSE.txt"))
    precondition(NotchQUpdateVerifier.notchQProblem(with: broken, expected: version, current: older, bundleIdentifier: identifier)?.contains("signature") == true, "modified bundle fails its code signature")

    // Full check → download → verify → unpack → validate, from a local feed (helper launch suppressed).
    let feedFile = root.appendingPathComponent("releases-feed.json"); try! feed.write(to: feedFile)
    func notchQUpdater(_ target: URL) -> NotchQUpdater {
        let updater = NotchQUpdater(directory: root.appendingPathComponent("Updates-" + UUID().uuidString))
        updater.feedURL = feedFile; updater.publicKey = publicKey; updater.current = older
        updater.installTarget = target; updater.bundleIdentifier = identifier; updater.launchHelper = false
        updater.terminate = { preconditionFailure("tests never quit") }
        return updater
    }
    func notchQWait(_ updater: NotchQUpdater, until done: (NotchQUpdater.Phase) -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !done(updater.phase) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    let installed = root.appendingPathComponent("Applications/NotchQ.app")
    try! files.createDirectory(at: installed, withIntermediateDirectories: true)
    let updater = notchQUpdater(installed)
    updater.notchQCheck(userInitiated: true)
    notchQWait(updater) { if case .available = $0 { return true }; if case .failed = $0 { return true }; return false }
    precondition(updater.available?.version == version, "check finds the update: \(updater.phase)")
    updater.notchQInstall()
    notchQWait(updater) { $0 == .installing || { if case .failed = $0 { return true }; return false }($0) }
    precondition(updater.phase == .installing, "verified update is ready to install: \(updater.phase)")
    precondition(files.fileExists(atPath: updater.directory.appendingPathComponent("\(version)/unpacked/NotchQ.app/Contents/Info.plist").path), "staged app unpacked")

    let wrongKey = notchQUpdater(installed); wrongKey.publicKey = stranger
    wrongKey.notchQCheck(userInitiated: true)
    notchQWait(wrongKey) { if case .available = $0 { return true }; return false }
    wrongKey.notchQInstall()
    notchQWait(wrongKey) { if case .failed = $0 { return true }; return $0 == .installing }
    if case .failed(let message) = wrongKey.phase { precondition(message.contains("signature") && !files.fileExists(atPath: wrongKey.directory.appendingPathComponent(version.description).path), "unverified download discarded") }
    else { preconditionFailure("update signed by another key must not install") }

    let readOnly = notchQUpdater(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
    readOnly.notchQCheck(userInitiated: true)
    notchQWait(readOnly) { if case .manualOnly = $0 { return true }; if case .available = $0 { return true }; return false }
    if case .manualOnly(let release, let message) = readOnly.phase { precondition(release.version == version && message.contains("Download")) }
    else { preconditionFailure("non-writable install offers a manual download") }

    let offline = notchQUpdater(installed); offline.feedURL = root.appendingPathComponent("missing.json")
    offline.notchQCheck(userInitiated: false)
    notchQWait(offline) { $0 != .checking }
    precondition(offline.phase == .idle, "automatic check failures stay quiet")

    // Install helper: swaps bundles, keeps a backup, and restores the old app if the swap fails.
    func notchQBundle(_ url: URL, marker: String) {
        try! files.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try! marker.write(to: url.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
    }
    func notchQMarker(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("Contents/marker"), encoding: .utf8) }
    let exited = Process(); exited.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try! exited.run(); exited.waitUntilExit()
    let gone = String(exited.processIdentifier)
    let target = root.appendingPathComponent("swap/Applications/NotchQ.app"), staged = root.appendingPathComponent("swap/Updates/new/NotchQ.app")
    let backup = root.appendingPathComponent("swap/Updates/NotchQ-previous.app")
    notchQBundle(target, marker: "old"); notchQBundle(staged, marker: "new")
    precondition(NotchQUpdater.notchQInstallMain([gone, staged.path, target.path, backup.path], relaunch: false) == 0, "swap succeeds")
    precondition(notchQMarker(target) == "new" && notchQMarker(backup) == "old" && !files.fileExists(atPath: staged.path), "new app in place, previous kept as backup")
    precondition(NotchQUpdater.notchQInstallMain([gone, root.appendingPathComponent("swap/none.app").path, target.path, backup.path], relaunch: false) == 5, "missing staged app fails")
    precondition(notchQMarker(target) == "new", "failed swap restores the installed app")
    let running = String(ProcessInfo.processInfo.processIdentifier)
    notchQBundle(staged, marker: "newer")
    precondition(NotchQUpdater.notchQInstallMain([running, staged.path, target.path, backup.path], relaunch: false, timeout: 0.3) == 3 && notchQMarker(target) == "new", "never swaps while the old app is still running")
    precondition(NotchQUpdater.notchQInstallMain(["x"], relaunch: false) == 2, "malformed helper arguments rejected")
    print("Passed updater checks: versions, feed selection, signatures, staged-bundle validation, download/verify/unpack, manual fallback, install swap and rollback")
}
