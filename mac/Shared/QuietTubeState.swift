// QuietTube for macOS — GPL-3.0-or-later.
import Foundation
import Darwin

enum QuietTubeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum QuietTubeClock {
    static func string(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct ProtectionSettings: Codable, Equatable {
    let schemaVersion: Int
    let enabled: Bool
    let pausedUntilUtc: String?
    let revision: Int64
    static let initial = ProtectionSettings(schemaVersion: 1, enabled: true, pausedUntilUtc: nil, revision: 1)
    func effectiveEnabled(at now: Date = Date()) -> Bool {
        enabled && (QuietTubeClock.date(pausedUntilUtc).map { $0 <= now } ?? true)
    }
    func validated() throws -> Self {
        guard schemaVersion == 1, revision >= 1, revision <= 9_007_199_254_740_991,
              pausedUntilUtc == nil || QuietTubeClock.date(pausedUntilUtc) != nil else {
            throw QuietTubeError.message("QuietTube settings could not be read. Preserve settings.json and repair the installation.")
        }
        return self
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, enabled, pausedUntilUtc, revision }
    init(schemaVersion: Int, enabled: Bool, pausedUntilUtc: String?, revision: Int64) {
        self.schemaVersion = schemaVersion; self.enabled = enabled
        self.pausedUntilUtc = pausedUntilUtc; self.revision = revision
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard fields.contains(.pausedUntilUtc) else { throw QuietTubeError.message("QuietTube settings are incomplete.") }
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        enabled = try fields.decode(Bool.self, forKey: .enabled)
        pausedUntilUtc = try fields.decodeIfPresent(String.self, forKey: .pausedUntilUtc)
        revision = try fields.decode(Int64.self, forKey: .revision)
        _ = try validated()
    }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(schemaVersion, forKey: .schemaVersion)
        try fields.encode(enabled, forKey: .enabled)
        try fields.encode(pausedUntilUtc, forKey: .pausedUntilUtc)
        try fields.encode(revision, forKey: .revision)
    }
}

struct BrowserAcknowledgment: Codable {
    let clientId: String
    let browser: String
    let extensionVersion: String
    let engineVersion: String
    let appliedEnabled: Bool
    let appliedRevision: Int64
    let youtubeMode: Int
    let enabledRulesets: Int
    let registeredScripts: Int
    let error: String?
    let lastSeenUtc: String
    func isFresh(at now: Date = Date()) -> Bool {
        guard let seen = QuietTubeClock.date(lastSeenUtc) else { return false }
        return now.timeIntervalSince(seen) >= -10 && now.timeIntervalSince(seen) < 70
    }
    func confirms(_ settings: ProtectionSettings, at now: Date = Date()) -> Bool {
        let enabled = settings.effectiveEnabled(at: now)
        return isFresh(at: now) && error == nil && appliedEnabled == enabled && appliedRevision == settings.revision
            && youtubeMode == (enabled ? 2 : 0) && (enabled ? enabledRulesets > 0 && registeredScripts > 0 : registeredScripts == 0)
    }
}

final class QuietTubeStore: @unchecked Sendable {
    let directory: URL
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    var clientsURL: URL { directory.appendingPathComponent("clients", isDirectory: true) }
    init(directory: URL) { self.directory = directory.standardizedFileURL }
    static func shared() throws -> QuietTubeStore {
        if let isolated = ProcessInfo.processInfo.environment["QUIETTUBE_DATA_DIR"], !isolated.isEmpty {
            return QuietTubeStore(directory: URL(fileURLWithPath: isolated, isDirectory: true))
        }
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BuildConfiguration.appGroup) else {
            throw QuietTubeError.message("QuietTube’s shared app container is unavailable. Reinstall the signed Mac app.")
        }
        return QuietTubeStore(directory: group.appendingPathComponent("QuietTube/data", isDirectory: true))
    }
    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw QuietTubeError.message("QuietTube’s data directory is not an ordinary folder owned by this user.")
        }
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        try ensureDirectory(directory)
        let descriptor = open(directory.appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw QuietTubeError.message("QuietTube could not open its settings lock.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw QuietTubeError.message("QuietTube’s settings lock is not a private regular file.")
        }
        let deadline = Date().addingTimeInterval(5)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw QuietTubeError.message("Settings are busy. Please try again.") }
            usleep(25_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
    private func readPrivateFile(_ url: URL, limit: Int = 65_536) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw QuietTubeError.message("QuietTube could not read its saved data.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else {
            throw QuietTubeError.message("QuietTube’s saved data is not a bounded private regular file.")
        }
        return try handle.readToEnd() ?? Data()
    }
    private func readUnlocked() throws -> ProtectionSettings {
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            // A dangling symlink is not a missing settings file.
            var info = stat()
            guard lstat(settingsURL.path, &info) != 0 && errno == ENOENT else {
                throw QuietTubeError.message("QuietTube’s settings file is not a regular file.")
            }
            try write(ProtectionSettings.initial, to: settingsURL)
            return .initial
        }
        do { return try JSONDecoder().decode(ProtectionSettings.self, from: readPrivateFile(settingsURL)) }
        catch { throw QuietTubeError.message("QuietTube settings could not be read. Preserve settings.json and repair the installation.") }
    }
    func read() throws -> ProtectionSettings { try locked { try readUnlocked() } }
    func setProtection(_ enabled: Bool, pauseMinutes: Int = 0) throws -> ProtectionSettings {
        guard (0...1440).contains(pauseMinutes) else { throw QuietTubeError.message("Invalid pause duration.") }
        return try locked {
            let previous = try readUnlocked()
            guard previous.revision < 9_007_199_254_740_991 else { throw QuietTubeError.message("QuietTube’s settings revision is exhausted.") }
            let next = ProtectionSettings(schemaVersion: 1, enabled: enabled,
                pausedUntilUtc: enabled && pauseMinutes > 0 ? QuietTubeClock.string(Date().addingTimeInterval(Double(pauseMinutes) * 60)) : nil,
                revision: previous.revision + 1)
            try write(next, to: settingsURL)
            return next
        }
    }
    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".quiettube-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw QuietTubeError.message("QuietTube could not save its data.") }
        var openFile = true
        defer { if openFile { close(descriptor) }; unlink(temporary.path) }
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw QuietTubeError.message("QuietTube could not finish saving its data.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw QuietTubeError.message("QuietTube could not flush its saved data.") }
        close(descriptor); openFile = false
        guard rename(temporary.path, url.path) == 0 else { throw QuietTubeError.message("QuietTube could not replace its saved data.") }
    }
    func saveClient(_ client: BrowserAcknowledgment) throws {
        guard let id = UUID(uuidString: client.clientId) else { throw QuietTubeError.message("Invalid client identifier.") }
        try write(client, to: clientsURL.appendingPathComponent(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".json"))
    }
    func clients() -> [BrowserAcknowledgment] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: clientsURL, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.prefix(100).compactMap { file in
            guard let data = try? readPrivateFile(file), let client = try? JSONDecoder().decode(BrowserAcknowledgment.self, from: data),
                  UUID(uuidString: client.clientId) != nil, ["Chrome", "Safari"].contains(client.browser) else { return nil }
            return client
        }.sorted { $0.lastSeenUtc > $1.lastSeenUtc }
    }
    struct Heartbeat: Codable { let pid: Int32; let seenAt: String }
    func heartbeat() throws { try write(Heartbeat(pid: getpid(), seenAt: QuietTubeClock.string()), to: directory.appendingPathComponent("tray.json")) }
    func appRunning() -> Bool {
        guard let data = try? readPrivateFile(directory.appendingPathComponent("tray.json")),
              let beat = try? JSONDecoder().decode(Heartbeat.self, from: data), let seen = QuietTubeClock.date(beat.seenAt) else { return false }
        let age = Date().timeIntervalSince(seen)
        guard age >= -5, age < 8, beat.pid > 0 else { return false }
        let exists = kill(beat.pid, 0)
        // Safari's sandbox may refuse the signal probe. EPERM still indicates
        // an existing process; the private heartbeat must also be fresh.
        return exists == 0 || errno == EPERM
    }
    func removeHeartbeat() {
        let url = directory.appendingPathComponent("tray.json")
        if let data = try? readPrivateFile(url), let beat = try? JSONDecoder().decode(Heartbeat.self, from: data), beat.pid == getpid() { try? FileManager.default.removeItem(at: url) }
    }
}
