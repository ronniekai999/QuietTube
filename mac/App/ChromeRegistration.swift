// QuietTube for macOS — GPL-3.0-or-later.
import Foundation
import Darwin

struct ChromeHostManifest: Codable, Equatable {
    let name: String
    let description: String
    let path: String
    let type: String
    let allowed_origins: [String]
    let quiettubeOwner: String
    var belongsToQuietTube: Bool {
        name == "com.quiettube.companion" && type == "stdio" && quiettubeOwner == "com.quiettube.mac"
            && allowed_origins == ["chrome-extension://\(BuildConfiguration.chromeExtensionId)/"]
    }
}

struct ChromeRegistration {
    let directory: URL
    let nativeHost: URL
    var manifestURL: URL { directory.appendingPathComponent("com.quiettube.companion.json") }
    var expected: ChromeHostManifest {
        ChromeHostManifest(name: "com.quiettube.companion", description: "QuietTube Mac companion", path: nativeHost.standardizedFileURL.path,
            type: "stdio", allowed_origins: ["chrome-extension://\(BuildConfiguration.chromeExtensionId)/"], quiettubeOwner: "com.quiettube.mac")
    }
    static var current: ChromeRegistration {
        let directory = ProcessInfo.processInfo.environment["QUIETTUBE_CHROME_HOSTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        return ChromeRegistration(directory: directory, nativeHost: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/QuietTubeNative"))
    }
    func read() throws -> ChromeHostManifest? {
        var info = stat()
        if lstat(manifestURL.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw QuietTubeError.message("Chrome’s QuietTube registration could not be read.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 65_536 else {
            throw QuietTubeError.message("Chrome’s QuietTube registration is not a private regular file.")
        }
        let descriptor = open(manifestURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw QuietTubeError.message("Chrome’s QuietTube registration could not be opened.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try handle.readToEnd() else { throw QuietTubeError.message("Chrome’s QuietTube registration is empty.") }
        return try JSONDecoder().decode(ChromeHostManifest.self, from: data)
    }
    var isConnected: Bool { (try? read()) == expected }
    func install() throws {
        guard FileManager.default.isExecutableFile(atPath: nativeHost.path) else { throw QuietTubeError.message("QuietTube’s Chrome companion is missing. Reinstall the Mac app.") }
        if let existing = try read(), !existing.belongsToQuietTube {
            throw QuietTubeError.message("Chrome already has a different registration named QuietTube. It was left unchanged.")
        }
        try QuietTubeStore(directory: directory).write(expected, to: manifestURL)
    }
    func remove() throws {
        guard let existing = try read() else { return }
        guard existing == expected else { throw QuietTubeError.message("Chrome’s registration belongs to another app installation. It was left unchanged.") }
        try FileManager.default.removeItem(at: manifestURL)
    }
}
