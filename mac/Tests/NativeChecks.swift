// QuietTube for macOS — GPL-3.0-or-later.
import Foundation
import Darwin

@main enum NativeChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("NativeChecks TEST_ROOT NATIVE_HOST") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString)
        let host = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var results: [String] = []; var errors: [String] = []
        func require(_ value: @autoclosure () throws -> Bool, _ message: String = "Assertion failed") throws {
            if try !value() { throw QuietTubeError.message(message) }
        }
        func rejected(_ action: () throws -> Void) throws {
            do { try action() } catch { return }
            throw QuietTubeError.message("Expected the operation to reject invalid input.")
        }
        func check(_ name: String, _ action: () throws -> Void) {
            do { try action(); results.append(name) } catch { errors.append(name + ": " + error.localizedDescription) }
        }
        func store(_ name: String) -> QuietTubeStore { QuietTubeStore(directory: root.appendingPathComponent(name)) }
        func command(_ values: [String: Any]) throws -> NativeCommand {
            try JSONDecoder().decode(NativeCommand.self, from: JSONSerialization.data(withJSONObject: values))
        }
        let identity: [String: Any] = ["type": "hello", "clientId": UUID().uuidString, "browser": "Chrome", "extensionVersion": "0.2.0", "engineVersion": "test"]
        check("Default settings contain an explicit null pause and persist with the expected schema") {
            let s = store("defaults"); try require(s.read() == .initial)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: s.settingsURL)) as! [String: Any]
            try require(json["pausedUntilUtc"] is NSNull); try require(json["schemaVersion"] as? Int == 1)
        }
        check("Explicit off survives a new store instance and advances the revision") {
            let s = store("persist"); let off = try s.setProtection(false)
            try require(off.revision == 2 && !off.effectiveEnabled()); try require(QuietTubeStore(directory: s.directory).read() == off)
        }
        check("Timed pause expires without changing explicit off behavior") {
            let s = store("pause"); let paused = try s.setProtection(true, pauseMinutes: 15)
            try require(!paused.effectiveEnabled()); try require(paused.effectiveEnabled(at: Date().addingTimeInterval(901)))
            let off = try s.setProtection(false, pauseMinutes: 15); try require(off.pausedUntilUtc == nil && !off.effectiveEnabled(at: .distantFuture))
            try rejected { _ = try s.setProtection(true, pauseMinutes: -1) }; try rejected { _ = try s.setProtection(true, pauseMinutes: 1441) }
        }
        check("Corrupt or incomplete settings are preserved and never silently reset") {
            let s = store("corrupt"); _ = try s.read()
            for content in ["{broken", "{\"schemaVersion\":1,\"enabled\":true,\"revision\":2}", "{\"schemaVersion\":1,\"enabled\":true,\"pausedUntilUtc\":\"invalid\",\"revision\":2}"] {
                let data = Data(content.utf8); try data.write(to: s.settingsURL)
                try rejected { _ = try s.setProtection(true) }; try require(Data(contentsOf: s.settingsURL) == data)
            }
        }
        check("Settings and lock symlinks cannot escape the private data directory") {
            let outside = root.appendingPathComponent("outside.json"); let sentinel = Data("sentinel".utf8); try sentinel.write(to: outside)
            for filename in ["settings.json", "settings.lock"] {
                let s = store("link-" + filename); try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: s.directory.appendingPathComponent(filename), withDestinationURL: outside)
                try rejected { _ = try s.setProtection(false) }; try require(Data(contentsOf: outside) == sentinel)
            }
        }
        check("A dangling settings symlink is rejected rather than treated as first launch") {
            let s = store("dangling"); try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: s.settingsURL, withDestinationURL: root.appendingPathComponent("missing"))
            try rejected { _ = try s.read() }; try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        }
        check("Native commands require a valid handshake and reject malformed scalar types") {
            let session = NativeSession(store: store("protocol"))
            try rejected { _ = try session.handle(command(["type": "setProtection", "enabled": false])) }
            var bad = identity; bad["clientId"] = "../escape"; try rejected { _ = try session.handle(command(bad)) }
            _ = try session.handle(command(identity))
            try rejected { _ = try command(["type": "setProtection", "enabled": [true]]) }
            try rejected { _ = try command(["type": "setProtection", "enabled": true, "pauseMinutes": true]) }
            try rejected { _ = try session.handle(command(["type": "status", "appliedEnabled": true, "appliedRevision": 1, "youtubeMode": 2, "enabledRulesets": 1000, "registeredScripts": 1])) }
        }
        check("Safari request metadata shares the same settings as a Chrome native session") {
            let s = store("safari"); let chrome = NativeSession(store: s); _ = try chrome.handle(command(identity))
            var safariIdentity = identity; safariIdentity["browser"] = "Safari"; safariIdentity["clientId"] = UUID().uuidString
            let safari = NativeSession(store: s); try safari.identify(command(safariIdentity), safari: true)
            _ = try safari.handle(command(["type": "setProtection", "enabled": false, "requestId": "safari-off"]))
            let value = try chrome.state(); try require(value["enabled"] as? Bool == false && value["revision"] as? Int64 == 2)
            try rejected { try safari.identify(command(identity), safari: true) }
        }
        check("Browser readiness needs fresh matching acknowledgments for both rules and scripts") {
            let s = store("acks"); let state = try s.read(); let session = NativeSession(store: s); _ = try session.handle(command(identity))
            _ = try session.handle(command(["type": "status", "appliedEnabled": true, "appliedRevision": state.revision, "youtubeMode": 2, "enabledRulesets": 1, "registeredScripts": 1]))
            let client = s.clients().first!; try require(client.confirms(state)); try require(!client.isFresh(at: Date().addingTimeInterval(80)))
            let off = try s.setProtection(false); try require(!client.confirms(off))
        }
        check("Native framing round trips Unicode and rejects truncated or excessive payloads") {
            let file = root.appendingPathComponent("frame"); FileManager.default.createFile(atPath: file.path, contents: Data())
            let output = try FileHandle(forWritingTo: file); try NativeFraming.write(["type": "state", "message": "QuietTube 🥹"], to: output); try output.close()
            let input = try FileHandle(forReadingFrom: file); let value = try JSONSerialization.jsonObject(with: NativeFraming.read(from: input)!) as! [String: Any]
            try require(value["message"] as? String == "QuietTube 🥹"); try require(NativeFraming.read(from: input) == nil); try input.close()
            for bytes in [[UInt8](arrayLiteral: 1, 0), [0, 0, 2, 0], [2, 0, 0, 0, 123]] {
                try Data(bytes).write(to: file); let truncated = try FileHandle(forReadingFrom: file)
                try rejected { _ = try NativeFraming.read(from: truncated) }; try truncated.close()
            }
        }
        check("Chrome registration contains only the exact extension origin and current helper") {
            let registration = ChromeRegistration(directory: root.appendingPathComponent("Chrome native hosts"), nativeHost: host)
            try registration.install(); try require(registration.read() == registration.expected)
            try registration.remove(); try require(registration.read() == nil)
        }
        check("Chrome registration preserves unrelated hosts and refuses foreign ownership") {
            let registration = ChromeRegistration(directory: root.appendingPathComponent("ownership"), nativeHost: host)
            try FileManager.default.createDirectory(at: registration.directory, withIntermediateDirectories: true)
            let other = registration.directory.appendingPathComponent("other.app.json"); let sentinel = Data("other app".utf8); try sentinel.write(to: other)
            try registration.install(); try require(Data(contentsOf: other) == sentinel)
            let foreign = Data("{\"name\":\"foreign\"}".utf8); try foreign.write(to: registration.manifestURL)
            try rejected { try registration.install() }; try rejected { try registration.remove() }
            try require(Data(contentsOf: registration.manifestURL) == foreign && Data(contentsOf: other) == sentinel)
        }
        check("Chrome updates replace only an owned registration and removal checks the current installation") {
            let folder = root.appendingPathComponent("upgrade"); let old = ChromeRegistration(directory: folder, nativeHost: URL(fileURLWithPath: "/usr/bin/true"))
            try old.install(); let current = ChromeRegistration(directory: folder, nativeHost: host); try current.install()
            try require(current.read() == current.expected); try rejected { try old.remove() }; try require(current.read() == current.expected)
        }
        check("Chrome registration symlinks preserve their outside target") {
            let registration = ChromeRegistration(directory: root.appendingPathComponent("chrome-link"), nativeHost: host)
            try FileManager.default.createDirectory(at: registration.directory, withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("outside-host"); let sentinel = Data("untouched".utf8); try sentinel.write(to: outside)
            try FileManager.default.createSymbolicLink(at: registration.manifestURL, withDestinationURL: outside)
            try rejected { try registration.install() }; try rejected { try registration.remove() }; try require(Data(contentsOf: outside) == sentinel)
        }
        check("Independent native processes serialize concurrent settings updates without lost revisions") {
            let s = store("concurrent"); _ = try s.read(); var processes: [Process] = []
            for index in 0..<12 {
                let process = Process(); process.executableURL = host; process.arguments = ["--set-enabled", index % 2 == 0 ? "true" : "false"]
                var environment = ProcessInfo.processInfo.environment; environment["QUIETTUBE_DATA_DIR"] = s.directory.path; process.environment = environment
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); processes.append(process)
            }
            for process in processes { process.waitUntilExit(); try require(process.terminationStatus == 0) }
            try require(s.read().revision == 13)
        }
        check("Native host refuses an unregistered Chrome extension origin") {
            let process = Process(); process.executableURL = host; process.arguments = ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]
            var environment = ProcessInfo.processInfo.environment; environment["QUIETTUBE_DATA_DIR"] = root.appendingPathComponent("rejected-origin").path
            process.environment = environment; process.standardError = FileHandle.nullDevice; try process.run(); process.waitUntilExit()
            try require(process.terminationStatus == 2); try require(!FileManager.default.fileExists(atPath: environment["QUIETTUBE_DATA_DIR"]! + "/settings.json"))
        }
        check("A private fresh app heartbeat is removed only by its owning process") {
            let s = store("heartbeat"); try require(!s.appRunning()); try s.heartbeat(); try require(s.appRunning())
            s.removeHeartbeat(); try require(!s.appRunning())
        }
        check("App promotion is atomic and refuses a destination that appeared during installation") {
            let applications = root.appendingPathComponent("Applications"); let stage = applications.appendingPathComponent(".QuietTube-install.fixture")
            let source = stage.appendingPathComponent("QuietTube.app"); let destination = applications.appendingPathComponent("QuietTube.app")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.quiettube.mac", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try plist.write(to: source.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let sentinel = destination.appendingPathComponent("foreign.txt"); try Data("preserved".utf8).write(to: sentinel)
            func promote(_ staged: URL = source) throws -> Int32 {
                let process = Process(); process.executableURL = host; process.arguments = ["--promote-app", staged.path, destination.path]
                var environment = ProcessInfo.processInfo.environment; environment["QUIETTUBE_TEST_APPLICATIONS_DIR"] = applications.path
                process.environment = environment; process.standardError = FileHandle.nullDevice; try process.run(); process.waitUntilExit(); return process.terminationStatus
            }
            try require(promote() == 2); try require(FileManager.default.fileExists(atPath: source.path))
            try require(String(contentsOf: sentinel, encoding: .utf8) == "preserved")
            try FileManager.default.removeItem(at: destination)
            try require(promote() == 0); try require(!FileManager.default.fileExists(atPath: source.path))
            try require(Bundle(url: destination)?.bundleIdentifier == "com.quiettube.mac")
            let backup = stage.appendingPathComponent("Previous QuietTube.app")
            try FileManager.default.moveItem(at: destination, to: backup)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("preserved".utf8).write(to: sentinel)
            try require(promote(backup) == 2); try require(FileManager.default.fileExists(atPath: backup.path))
            try require(String(contentsOf: sentinel, encoding: .utf8) == "preserved")
            try FileManager.default.removeItem(at: destination)
            try require(promote(backup) == 0); try require(Bundle(url: destination)?.bundleIdentifier == "com.quiettube.mac")
        }
        let report: [String: Any] = ["testedAtUtc": QuietTubeClock.string(), "platform": "macOS", "appVersion": BuildConfiguration.version,
            "results": results, "errors": errors, "scope": "Real private files, native processes, locking, framing, shared Safari protocol, and Chrome registration. Browser acceptance is separate."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10])); if !errors.isEmpty { exit(1) }
    }
}
