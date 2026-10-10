// QuietTube for macOS — GPL-3.0-or-later.
import Foundation

struct NativeCommand: Decodable {
    let type: String
    let requestId: String?
    let clientId: String?
    let browser: String?
    let extensionVersion: String?
    let engineVersion: String?
    let enabled: Bool?
    let pauseMinutes: Int?
    let appliedEnabled: Bool?
    let appliedRevision: Int64?
    let youtubeMode: Int?
    let enabledRulesets: Int?
    let registeredScripts: Int?
    let error: String?
}

final class NativeSession {
    let store: QuietTubeStore
    private(set) var clientId: String?
    private var browser = "Chrome"
    private var extensionVersion = "unknown"
    private var engineVersion = "unknown"
    init(store: QuietTubeStore) { self.store = store }
    func identify(_ command: NativeCommand, safari: Bool = false) throws {
        guard let id = command.clientId, UUID(uuidString: id) != nil,
              let version = command.extensionVersion, !version.isEmpty, version.count <= 40,
              let engine = command.engineVersion, !engine.isEmpty, engine.count <= 60,
              command.browser == (safari ? "Safari" : "Chrome") else { throw QuietTubeError.message("Invalid companion handshake.") }
        clientId = id; browser = safari ? "Safari" : "Chrome"
        extensionVersion = version; engineVersion = engine
    }
    func state(requestId: String? = nil) throws -> [String: Any] {
        let settings = try store.read()
        return ["type": "state", "requestId": requestId.map { $0 as Any } ?? NSNull(), "schemaVersion": 1,
            "enabled": settings.enabled, "effectiveEnabled": settings.effectiveEnabled(),
            "pausedUntilUtc": settings.pausedUntilUtc.map { $0 as Any } ?? NSNull(), "revision": settings.revision,
            "appRunning": store.appRunning(), "appVersion": BuildConfiguration.version]
    }
    func handle(_ command: NativeCommand) throws -> [String: Any] {
        guard (command.requestId?.count ?? 0) <= 80 else { throw QuietTubeError.message("Invalid request identifier.") }
        if command.type == "hello" {
            try identify(command, safari: command.browser == "Safari")
            return try state(requestId: command.requestId)
        }
        guard let clientId else { throw QuietTubeError.message("Send hello before commands.") }
        switch command.type {
        case "getState": return try state(requestId: command.requestId)
        case "setProtection":
            guard let enabled = command.enabled else { throw QuietTubeError.message("Invalid protection setting.") }
            _ = try store.setProtection(enabled, pauseMinutes: command.pauseMinutes ?? 0)
            return try state(requestId: command.requestId)
        case "status":
            guard let enabled = command.appliedEnabled, let revision = command.appliedRevision, revision >= 0,
                  let mode = command.youtubeMode, (0...3).contains(mode),
                  let rules = command.enabledRulesets, (0...100).contains(rules),
                  let scripts = command.registeredScripts, (0...10_000).contains(scripts) else { throw QuietTubeError.message("Invalid filtering status.") }
            let error = command.error.map { String($0.prefix(300)) }
            try store.saveClient(BrowserAcknowledgment(clientId: clientId, browser: browser, extensionVersion: extensionVersion,
                engineVersion: engineVersion, appliedEnabled: enabled, appliedRevision: revision, youtubeMode: mode,
                enabledRulesets: rules, registeredScripts: scripts, error: error, lastSeenUtc: QuietTubeClock.string()))
            return ["type": "ack", "requestId": command.requestId.map { $0 as Any } ?? NSNull()]
        default: throw QuietTubeError.message("Unsupported companion command.")
        }
    }
    static func error(_ error: Error, requestId: String? = nil) -> [String: Any] {
        ["type": "error", "requestId": requestId.map { $0 as Any } ?? NSNull(), "message": error.localizedDescription]
    }
}

enum NativeFraming {
    static let maximumBytes = 65_536
    static func read(from input: FileHandle) throws -> Data? {
        let header = input.readData(ofLength: 4)
        if header.isEmpty { return nil }
        guard header.count == 4 else { throw QuietTubeError.message("Incomplete native message header.") }
        let size = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard size > 0, size <= maximumBytes else { throw QuietTubeError.message("Invalid native message length.") }
        let data = input.readData(ofLength: Int(size))
        guard data.count == size else { throw QuietTubeError.message("Incomplete native message payload.") }
        return data
    }
    static func write(_ value: [String: Any], to output: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= maximumBytes else { throw QuietTubeError.message("Native message exceeds the limit.") }
        let size = UInt32(data.count)
        let header = Data((0..<4).map { UInt8((size >> ($0 * 8)) & 0xff) })
        try output.write(contentsOf: header + data)
    }
}
