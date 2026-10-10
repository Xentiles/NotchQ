import AppKit
import CryptoKit
import Darwin

/// A release version, written B(eta)v<major>.<minor>.<patch> in tags and the UI.
struct NotchQVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    init?(tag: String) {
        guard tag.hasPrefix("Bv") else { return nil }
        self.init(String(tag.dropFirst(2)))
    }
    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }
    var description: String { "Bv" + parts.map(String.init).joined(separator: ".") }
    static func < (lhs: NotchQVersion, rhs: NotchQVersion) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct NotchQRelease: Equatable {
    let version: NotchQVersion
    let page: URL
    let archive: URL
    let signature: URL
    static func == (lhs: NotchQRelease, rhs: NotchQRelease) -> Bool { lhs.version == rhs.version && lhs.archive == rhs.archive }

    /// Picks the newest non-draft Bv release above `current` that carries a signed update archive.
    /// Uses the full release list: every NotchQ release is a GitHub prerelease.
    static func notchQNewest(in data: Data, above current: NotchQVersion) -> NotchQRelease? {
        guard let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return releases.compactMap { release -> NotchQRelease? in
            guard release["draft"] as? Bool != true, let tag = release["tag_name"] as? String,
                  let version = NotchQVersion(tag: tag), version > current,
                  let page = (release["html_url"] as? String).flatMap(URL.init(string:)),
                  let assets = release["assets"] as? [[String: Any]] else { return nil }
            func asset(_ name: String) -> URL? {
                assets.first { $0["name"] as? String == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            }
            #if NOTCHQ_TESTING
            let schemes: Set<String> = ["https", "file"]   // local fixtures in tests only
            #else
            let schemes: Set<String> = ["https"]
            #endif
            guard let archive = asset("NotchQ-\(version).zip"), let signature = asset("NotchQ-\(version).zip.sig"),
                  schemes.contains(archive.scheme ?? ""), schemes.contains(signature.scheme ?? "") else { return nil }
            return NotchQRelease(version: version, page: page, archive: archive, signature: signature)
        }.max { $0.version < $1.version }
    }
}

enum NotchQUpdateVerifier {
    /// Ed25519 signature (base64 text) over the exact archive bytes, made with a key kept off GitHub.
    static func notchQSignatureValid(_ archive: Data, signature: Data, publicKey: String) -> Bool {
        guard let key = Data(base64Encoded: publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(raw, for: archive)
    }

    /// Returns why a staged app must not be installed, or nil when it is safe to swap in.
    static func notchQProblem(with app: URL, expected: NotchQVersion, current: NotchQVersion, bundleIdentifier: String) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return "The update is not a NotchQ app." }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { return "The update is for a different app." }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap({ NotchQVersion($0) }), version == expected, version > current else {
            return "The update's version does not match the release."
        }
        guard let executable = info["CFBundleExecutable"] as? String,
              let architectures = Bundle(url: app)?.executableArchitectures?.map(\.intValue) else { return "The update has no app binary." }
        #if arch(arm64)
        let needed = NSBundleExecutableArchitectureARM64
        #else
        let needed = NSBundleExecutableArchitectureX86_64
        #endif
        guard architectures.contains(needed), FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + executable).path) else {
            return "The update does not run on this Mac's processor."
        }
        guard notchQRun("/usr/bin/codesign", ["--verify", "--strict", app.path]) == 0 else { return "The update's code signature is invalid." }
        return nil
    }

    @discardableResult
    static func notchQRun(_ tool: String, _ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool); task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}

/// Checks GitHub Releases, then downloads, verifies and installs updates on request.
/// Main-thread class; installation is handed to the new app's own binary (`--install-update`).
final class NotchQUpdater {
    enum Phase: Equatable {
        case idle, checking, upToDate, available(NotchQRelease), downloading(Int?), installing
        case manualOnly(NotchQRelease, String), failed(String)
    }
    private(set) var phase: Phase = .idle { didSet { notchQLogPhase(previous: oldValue); onChange?() } }
    private func notchQLogPhase(previous: Phase) {
        let log = NotchQDiagnostics.shared
        switch phase {
        case .upToDate: log.record(.updateChecked, reason: .upToDate, detail: current.description)
        case .available(let release): if previous != phase { log.record(.updateAvailable, detail: "\(current) -> \(release.version)") }
        case .manualOnly(let release, _): log.record(.updateAvailable, reason: .manualOnly, detail: "\(current) -> \(release.version)")
        case .installing: log.record(.updateInstalling, detail: available.map { "\(current) -> \($0.version)" })
        case .failed(let message):
            let reason: NotchQDiagnostics.Reason = message.contains("signature") ? .signature : message.contains("download") ? .download : message.contains("check for updates") ? .disconnected : .rejected
            log.record(.updateFailed, reason: reason)
        case .idle, .checking, .downloading: break
        }
    }
    #if NOTCHQ_TESTING
    func notchQPreview(_ phase: Phase) { self.phase = phase }
    #endif
    var onChange: (() -> Void)?
    var feedURL = URL(string: "https://api.github.com/repos/Xentiles/NotchQ/releases?per_page=30")!
    var publicKey = Bundle.main.object(forInfoDictionaryKey: "NotchQUpdatePublicKey") as? String ?? ""
    var current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { NotchQVersion($0) } ?? NotchQVersion("0.0.0")!
    var installTarget = Bundle.main.bundleURL
    var bundleIdentifier = Bundle.main.bundleIdentifier ?? NotchQPreferences.applicationIdentifier
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var launchHelper = true
    let directory: URL
    private let session: URLSession
    private var timer: Timer?
    private var progress: NSKeyValueObservation?
    static let checkInterval: TimeInterval = 86_400

    init(directory: URL = NotchQPreferences.supportDirectory.appendingPathComponent("Updates", isDirectory: true)) {
        self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        #if NOTCHQ_TESTING
        if let feed = ProcessInfo.processInfo.environment["NOTCHQ_UPDATE_FEED"].flatMap(URL.init(string:)) { feedURL = feed }
        #endif
    }

    var lastChecked: Date? { NotchQPreferences.defaults.object(forKey: "lastUpdateCheck") as? Date }
    var available: NotchQRelease? {
        switch phase { case .available(let release), .manualOnly(let release, _): return release; default: return nil }
    }

    /// First automatic check 30 s after launch, then whenever a day has passed (checked hourly and on wake).
    func notchQStart() {
        notchQCleanUp(after: 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.notchQCheckIfDue() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.notchQCheckIfDue() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func notchQCheckIfDue(now: Date = Date()) {
        guard NotchQPreferences.autoCheckUpdates else { return }
        if let last = lastChecked, now.timeIntervalSince(last) < Self.checkInterval {
            // Checked recently (e.g. before a relaunch): show what that check found, without a request.
            if phase == .idle { notchQEvaluate(try? Data(contentsOf: directory.appendingPathComponent("releases.json"))) }
            return
        }
        notchQCheck(userInitiated: false)
    }
    private func notchQEvaluate(_ feed: Data?) {
        guard let feed = feed, (try? JSONSerialization.jsonObject(with: feed)) is [Any] else { return }
        guard let release = NotchQRelease.notchQNewest(in: feed, above: current) else { phase = .upToDate; return }
        phase = notchQCanInstall() ? .available(release)
            : .manualOnly(release, "NotchQ can't replace itself in this folder. Download \(release.version) from GitHub instead.")
    }

    func notchQCheck(userInitiated: Bool) {
        switch phase { case .checking, .downloading, .installing: return; default: break }
        let previous = phase
        phase = .checking
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotchQ/\(current.parts.map(String.init).joined(separator: "."))", forHTTPHeaderField: "User-Agent")
        let cache = directory.appendingPathComponent("releases.json")
        if let etag = NotchQPreferences.defaults.string(forKey: "updateFeedETag"), FileManager.default.fileExists(atPath: cache.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        // The updater lives as long as the app, so these callbacks keep it strongly.
        session.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? (response?.url?.isFileURL == true ? 200 : 0)
                var body: Data?
                if status == 304 { body = try? Data(contentsOf: cache) }
                else if status == 200, let data = data {
                    body = data
                    try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try? data.write(to: cache, options: .atomic)
                    NotchQPreferences.defaults.set((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), forKey: "updateFeedETag")
                }
                guard let feed = body, (try? JSONSerialization.jsonObject(with: feed)) is [Any] else {
                    // Automatic checks fail quietly and retry later; a user's Check now explains.
                    self.phase = userInitiated ? .failed("Couldn't check for updates. Check your connection and try again.") : previous == .checking ? .idle : previous
                    return
                }
                NotchQPreferences.defaults.set(Date(), forKey: "lastUpdateCheck")
                self.notchQEvaluate(feed)
            }
        }.resume()
    }

    /// The app and its folder must be writable to swap in place (e.g. not for a standard user in /Applications).
    func notchQCanInstall() -> Bool {
        let files = FileManager.default
        return files.isWritableFile(atPath: installTarget.path) && files.isWritableFile(atPath: installTarget.deletingLastPathComponent().path)
            && !installTarget.path.hasPrefix("/Volumes/") && !installTarget.path.contains("/AppTranslocation/")
    }

    func notchQInstall() {
        guard case .available(let release) = phase else { return }
        phase = .downloading(nil)
        let folder = directory.appendingPathComponent(release.version.description, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { phase = .failed("Couldn't prepare the update folder."); return }
        session.dataTask(with: release.signature) { signature, _, _ in
            let task = self.session.downloadTask(with: release.archive) { location, response, _ in
                let archive = folder.appendingPathComponent("NotchQ.zip")
                let status = (response as? HTTPURLResponse)?.statusCode ?? (response?.url?.isFileURL == true ? 200 : 0)
                let moved = location.map { (try? FileManager.default.moveItem(at: $0, to: archive)) != nil } ?? false
                DispatchQueue.main.async {
                    self.progress = nil
                    guard status == 200, moved, let signature = signature else { self.phase = .failed("The update download failed. Try again later."); return }
                    self.notchQFinish(release, archive: archive, signature: signature, folder: folder)
                }
            }
            DispatchQueue.main.async {
                self.progress = task.progress.observe(\.fractionCompleted) { progress, _ in
                    let percent = Int(progress.fractionCompleted * 100)
                    DispatchQueue.main.async { if case .downloading(let shown) = self.phase, shown != percent { self.phase = .downloading(percent) } }
                }
            }
            task.resume()
        }.resume()
    }

    private func notchQFinish(_ release: NotchQRelease, archive: URL, signature: Data, folder: URL) {
        func discard(_ message: String) { try? FileManager.default.removeItem(at: folder); phase = .failed(message) }
        guard let bytes = try? Data(contentsOf: archive), NotchQUpdateVerifier.notchQSignatureValid(bytes, signature: signature, publicKey: publicKey) else {
            discard("The update failed its signature check and was discarded."); return
        }
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        guard NotchQUpdateVerifier.notchQRun("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) == 0 else { discard("The update couldn't be unpacked."); return }
        let staged = unpacked.appendingPathComponent("NotchQ.app")
        if let problem = NotchQUpdateVerifier.notchQProblem(with: staged, expected: release.version, current: current, bundleIdentifier: bundleIdentifier) {
            discard(problem + " It was discarded."); return
        }
        phase = .installing
        let backup = directory.appendingPathComponent("NotchQ-previous.app")
        let helper = Process()
        helper.executableURL = staged.appendingPathComponent("Contents/MacOS/NotchQ")
        helper.arguments = ["--install-update", String(ProcessInfo.processInfo.processIdentifier), staged.path, installTarget.path, backup.path]
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        guard launchHelper else { return }
        do { try helper.run() } catch { discard("The update couldn't be started."); return }
        terminate()
    }

    /// Removes staging folders and the previous version once this version has been running for a while.
    func notchQCleanUp(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            switch self.phase { case .downloading, .installing: return; default: break }
            let directory = self.directory, files = FileManager.default
            for item in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent != "releases.json" {
                try? files.removeItem(at: item)
            }
        }
    }

    /// `NotchQ --install-update <pid> <staged.app> <target.app> <backup.app>`, run from the new version.
    /// Waits for the old app to quit, swaps the bundles (restoring the old one on failure) and reopens NotchQ.
    static func notchQInstallMain(_ arguments: [String], relaunch: Bool = ProcessInfo.processInfo.environment["NOTCHQ_NO_RELAUNCH"] == nil, timeout: TimeInterval = 10) -> Int32 {
        guard arguments.count == 4, let pid = Int32(arguments[0]) else { return 2 }
        let staged = URL(fileURLWithPath: arguments[1]), target = URL(fileURLWithPath: arguments[2]), backup = URL(fileURLWithPath: arguments[3])
        let files = FileManager.default
        let until = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 && Date() < until { usleep(100_000) }
        guard kill(pid, 0) != 0 else { return 3 }
        func reopen() { if relaunch { NotchQUpdateVerifier.notchQRun("/usr/bin/open", [target.path]) } }
        try? files.removeItem(at: backup)
        do { try files.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { reopen(); return 4 }
        do { try files.moveItem(at: target, to: backup) } catch { reopen(); return 4 }
        do { try files.moveItem(at: staged, to: target) }
        catch {
            try? files.removeItem(at: target)
            try? files.moveItem(at: backup, to: target)
            NotchQDiagnostics.shared.record(.updateFailed, reason: .rejected, detail: "helper=restored-previous")
            reopen(); return 5
        }
        reopen()
        NotchQDiagnostics.shared.record(.updateInstalling, detail: "helper=installed")
        return 0
    }
}
