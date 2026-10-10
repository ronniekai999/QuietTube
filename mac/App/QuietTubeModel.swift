// QuietTube for macOS — GPL-3.0-or-later.
import AppKit
import SafariServices
import ServiceManagement
import SwiftUI

@MainActor final class QuietTubeModel: ObservableObject {
    @Published private(set) var settings = ProtectionSettings.initial
    @Published private(set) var clients: [BrowserAcknowledgment] = []
    @Published private(set) var safariEnabled = false
    @Published private(set) var chromeRegistered = false
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published var notice: String?
    private let store: QuietTubeStore?
    private var timer: Timer?
    private var refreshing = false
    private var signature: String?
    var openSetup: (() -> Void)?
    var closePopover: (() -> Void)?
    init() {
        do { store = try .shared() }
        catch { store = nil; self.error = error.localizedDescription }
    }
    var effectiveEnabled: Bool { settings.effectiveEnabled() }
    var freshClients: [BrowserAcknowledgment] { clients.filter { $0.isFresh() } }
    var confirmedClients: [BrowserAcknowledgment] { freshClients.filter { $0.confirms(settings) } }
    var hasAttention: Bool { error != nil || freshClients.contains { $0.error != nil } }
    var title: String {
        if error != nil { return "Settings need attention" }
        if !settings.enabled { return "Protection is off" }
        if !effectiveEnabled { return "Taking a short break" }
        if freshClients.isEmpty { return "Let’s get connected" }
        if hasAttention { return "Filtering needs attention" }
        if confirmedClients.count < freshClients.count { return "Applying protection…" }
        return "Protection is on"
    }
    var detail: String {
        if let error { return error }
        if !settings.enabled { return "YouTube loads without QuietTube filtering." }
        if !effectiveEnabled, let deadline = QuietTubeClock.date(settings.pausedUntilUtc) {
            return "Resumes at \(deadline.formatted(date: .omitted, time: .shortened)). You can resume whenever you like."
        }
        if freshClients.isEmpty { return "Enable QuietTube in Safari or Chrome, then allow it on YouTube." }
        if hasAttention { return "Open the browser’s QuietTube popup to check its permissions and filtering status." }
        if confirmedClients.count < freshClients.count { return "Waiting for your connected browsers to confirm this setting." }
        return "Your connected browser\(confirmedClients.count == 1 ? " has" : "s have") confirmed YouTube filtering. Reload any video already open."
    }
    func browserSummary(_ browser: String) -> (String, Bool) {
        let live = freshClients.filter { $0.browser == browser }
        if !live.isEmpty {
            if live.contains(where: { $0.error != nil }) { return ("Needs attention", false) }
            if live.allSatisfy({ $0.confirms(settings) }) { return (effectiveEnabled ? "Protection confirmed" : "Pause / off confirmed", true) }
            return ("Applying settings…", false)
        }
        if browser == "Safari" { return (safariEnabled ? "Open YouTube to connect" : "Enable extension", false) }
        return (chromeRegistered ? "Load the extension" : "Connect companion", false)
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func stop() { timer?.invalidate(); timer = nil; store?.removeHeartbeat() }
    func refresh() {
        guard let store, !refreshing else { return }
        refreshing = true
        Task {
            let result = await Task.detached { () -> Result<(ProtectionSettings, [BrowserAcknowledgment]), Error> in
                Result { try store.heartbeat(); return (try store.read(), store.clients()) }
            }.value
            refreshing = false
            switch result {
            case let .success((settings, clients)):
                self.settings = settings; self.clients = clients; error = nil
                let next = "\(settings.revision):\(settings.effectiveEnabled())"
                if signature != next {
                    signature = next
                    SFSafariApplication.dispatchMessage(withName: "quiettube-state-changed", toExtensionWithIdentifier: BuildConfiguration.safariExtensionId,
                        userInfo: ["revision": settings.revision]) { _ in }
                }
            case let .failure(failure): error = failure.localizedDescription
            }
            chromeRegistered = ChromeRegistration.current.isConnected
            loginStatus = SMAppService.mainApp.status
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: BuildConfiguration.safariExtensionId) { state, _ in
                Task { @MainActor in self.safariEnabled = state?.isEnabled == true }
            }
        }
    }
    func protection(_ enabled: Bool, minutes: Int = 0) {
        guard let store, !busy else { return }
        busy = true; notice = nil
        Task {
            let result = await Task.detached { Result { try store.setProtection(enabled, pauseMinutes: minutes) } }.value
            busy = false
            switch result {
            case let .success(settings): self.settings = settings; refresh()
            case let .failure(failure): notice = failure.localizedDescription
            }
        }
    }
    func connectChrome() {
        do { try ChromeRegistration.current.install(); chromeRegistered = true; notice = "Chrome companion connected. Load the extension to finish setup." }
        catch { notice = error.localizedDescription }
    }
    func disconnectChrome() {
        do { try ChromeRegistration.current.remove(); chromeRegistered = false; notice = "QuietTube’s Chrome companion was disconnected." }
        catch { notice = error.localizedDescription }
    }
    func safariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: BuildConfiguration.safariExtensionId) { [weak self] failure in
            if let failure { Task { @MainActor in self?.notice = failure.localizedDescription } }
        }
    }
    func chromeSettings() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { notice = "Install Google Chrome to use its QuietTube extension."; return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.arguments = ["chrome://extensions/"]
        NSWorkspace.shared.openApplication(at: chrome, configuration: configuration) { [weak self] _, failure in
            if let failure { Task { @MainActor in self?.notice = failure.localizedDescription } }
        }
    }
    var chromeExtensionURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ChromeExtension", isDirectory: true) }
    func revealChromeExtension() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chromeExtensionURL.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([chromeExtensionURL]); notice = "Extension folder path copied. Select this folder in Chrome’s Load unpacked dialog."
    }
    func launchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            if loginStatus == .requiresApproval { notice = "Allow QuietTube in System Settings → General → Login Items." }
        } catch { notice = error.localizedDescription }
    }
    func exportDiagnostics() {
        guard let store else { return }
        closePopover?(); NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "QuietTube-diagnostics.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let state = try JSONSerialization.jsonObject(with: encoder.encode(store.read()))
            var browsers = try JSONSerialization.jsonObject(with: encoder.encode(store.clients())) as? [[String: Any]] ?? []
            for index in browsers.indices {
                if let text = browsers[index]["error"] as? String {
                    browsers[index]["error"] = text.replacingOccurrences(of: "https?://[^\\s]+", with: "[URL removed]", options: .regularExpression)
                }
            }
            let data = try JSONSerialization.data(withJSONObject: ["appVersion": BuildConfiguration.version, "platform": "macOS",
                "exportedAtUtc": QuietTubeClock.string(), "settings": state, "clients": browsers,
                "safariExtensionEnabled": safariEnabled, "chromeCompanionRegistered": chromeRegistered,
                "launchAtLogin": loginStatus == .enabled], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic); notice = "Diagnostics exported."
        } catch { notice = error.localizedDescription }
    }
}
