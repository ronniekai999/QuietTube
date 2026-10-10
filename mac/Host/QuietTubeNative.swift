// QuietTube for macOS — GPL-3.0-or-later.
import Foundation
import Darwin

@main enum QuietTubeNative {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 3, args[0] == "--promote-app" {
                try promoteApp(from: URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2])); return
            }
            let store = try QuietTubeStore.shared()
            if args == ["--status"] {
                try printValue(["settings": encoded(try store.read()), "clients": store.clients().map { encoded($0) }]); return
            }
            if args.count == 2, args[0] == "--set-enabled", ["true", "false"].contains(args[1]) {
                try printValue(encoded(try store.setProtection(args[1] == "true"))); return
            }
            if args.count == 2, args[0] == "--pause", let minutes = Int(args[1]) {
                try printValue(encoded(try store.setProtection(true, pauseMinutes: minutes))); return
            }
            guard args.first == "chrome-extension://\(BuildConfiguration.chromeExtensionId)/" else {
                throw QuietTubeError.message("QuietTube’s native host must be launched by its registered Chrome extension.")
            }
            let session = NativeSession(store: store)
            let gate = NSLock()
            var signature: Data?
            var lastPing = Date()
            func sendState(requestId: String? = nil, onlyIfChanged: Bool = false) throws {
                let value = try session.state(requestId: requestId)
                let next = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                if onlyIfChanged && next == signature { return }
                signature = next
                try NativeFraming.write(value, to: .standardOutput)
            }
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.quiettube.native-state"))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler {
                gate.lock(); defer { gate.unlock() }
                guard session.clientId != nil else { return }
                do {
                    try sendState(onlyIfChanged: true)
                    if Date().timeIntervalSince(lastPing) > 20 {
                        try NativeFraming.write(["type": "ping"], to: .standardOutput); lastPing = Date()
                    }
                } catch { /* The reader reports an error or exits when the browser closes its pipes. */ }
            }
            timer.resume()
            defer { timer.cancel() }
            while let data = try NativeFraming.read(from: .standardInput) {
                gate.lock(); defer { gate.unlock() }
                var requestId: String?
                do {
                    let command = try JSONDecoder().decode(NativeCommand.self, from: data)
                    requestId = command.requestId
                    let response = try session.handle(command)
                    if response["type"] as? String == "state" { try sendState(requestId: requestId) }
                    // Status is one-way in Chrome. Safari's handler sends an ack.
                } catch { try NativeFraming.write(NativeSession.error(error, requestId: requestId), to: .standardOutput) }
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8)); exit(2)
        }
    }
    static func encoded<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? NSNull() }
    static func promoteApp(from source: URL, to destination: URL) throws {
        let source = source.standardizedFileURL; let destination = destination.standardizedFileURL
        let applications = (ProcessInfo.processInfo.environment["QUIETTUBE_TEST_APPLICATIONS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")).standardizedFileURL
        let stage = source.deletingLastPathComponent()
        var info = stat()
        guard destination == applications.appendingPathComponent("QuietTube.app"), ["QuietTube.app", "Previous QuietTube.app"].contains(source.lastPathComponent),
              stage.deletingLastPathComponent() == applications, stage.lastPathComponent.hasPrefix(".QuietTube-install."),
              lstat(applications.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              lstat(stage.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              Bundle(url: source)?.bundleIdentifier == "com.quiettube.mac" else { throw QuietTubeError.message("Invalid staged QuietTube app destination.") }
        // Atomic, exclusive rename: a newly appeared directory or symlink is
        // never overwritten, and mv cannot nest the app inside that directory.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw QuietTubeError.message("The app destination changed or could not be updated. Existing files were left unchanged.")
        }
    }
    static func printValue(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
