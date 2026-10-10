// QuietTube for macOS — GPL-3.0-or-later.
import SwiftUI
import ServiceManagement

enum QuietTubePalette {
    static let background = Color(red: 21/255, green: 26/255, blue: 25/255)
    static let card = Color(red: 32/255, green: 41/255, blue: 35/255)
    static let green = Color(red: 184/255, green: 237/255, blue: 156/255)
    static let secondary = Color(red: 174/255, green: 190/255, blue: 178/255)
    static let amber = Color(red: 232/255, green: 181/255, blue: 93/255)
}

struct QuietTubeMark: View {
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: "play.fill").font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(QuietTubePalette.background).frame(width: size, height: size)
            .background(QuietTubePalette.green, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct QuietTubeButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.vertical, 11).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(primary ? QuietTubePalette.background : Color.white.opacity(0.94))
            .background(primary ? QuietTubePalette.green : Color.white.opacity(configuration.isPressed ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct ProtectionCard: View {
    @ObservedObject var model: QuietTubeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(model.hasAttention ? QuietTubePalette.amber : QuietTubePalette.green).frame(width: 6, height: 6)
                Text(model.hasAttention ? "NEEDS ATTENTION" : model.effectiveEnabled ? "YOUTUBE PROTECTION" : "PAUSED OR OFF")
                    .font(.system(size: 10, weight: .bold)).tracking(1.2)
            }.foregroundStyle(model.hasAttention ? QuietTubePalette.amber : QuietTubePalette.green)
            Text(model.title).font(.system(size: 24, weight: .semibold)).tracking(-0.6)
            Text(model.detail).font(.system(size: 12)).foregroundStyle(QuietTubePalette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(QuietTubePalette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
            .accessibilityElement(children: .combine)
    }
}

struct BrowserRow: View {
    @ObservedObject var model: QuietTubeModel
    let browser: String
    var body: some View {
        let summary = model.browserSummary(browser)
        HStack {
            Image(systemName: browser == "Safari" ? "safari" : "globe").font(.system(size: 19)).frame(width: 24)
            Text(browser).font(.system(size: 12, weight: .semibold))
            Spacer()
            Circle().fill(summary.1 ? QuietTubePalette.green : QuietTubePalette.amber).frame(width: 6, height: 6)
            Text(summary.0).font(.system(size: 11)).foregroundStyle(QuietTubePalette.secondary)
        }.padding(.vertical, 5).accessibilityElement(children: .combine)
    }
}

struct QuietTubePanel: View {
    @ObservedObject var model: QuietTubeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                QuietTubeMark()
                VStack(alignment: .leading, spacing: 3) {
                    Text("QuietTube").font(.system(size: 23, weight: .semibold)).tracking(-0.7)
                    Text("YouTube, with fewer interruptions.").font(.system(size: 11)).foregroundStyle(QuietTubePalette.secondary)
                }
            }
            ProtectionCard(model: model)
            VStack(spacing: 8) {
                Button(model.effectiveEnabled ? "Turn protection off" : "Turn protection on") { model.protection(!model.effectiveEnabled) }
                    .buttonStyle(QuietTubeButton(primary: true)).disabled(model.busy || model.error != nil)
                Button("Pause 15 minutes") { model.protection(true, minutes: 15) }
                    .buttonStyle(QuietTubeButton()).disabled(model.busy || !model.effectiveEnabled || model.error != nil)
            }
            VStack(spacing: 3) { BrowserRow(model: model, browser: "Safari"); BrowserRow(model: model, browser: "Chrome") }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(QuietTubePalette.amber).fixedSize(horizontal: false, vertical: true) }
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Button("Setup & settings") { model.closePopover?(); model.openSetup?() }.buttonStyle(.plain).foregroundStyle(QuietTubePalette.green)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(QuietTubePalette.secondary)
            }.font(.system(size: 11))
        }.padding(24).frame(width: 370).foregroundStyle(Color.white.opacity(0.94)).background(QuietTubePalette.background)
            .preferredColorScheme(.dark)
    }
}

struct QuietTubeSetup: View {
    @ObservedObject var model: QuietTubeModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    QuietTubeMark(size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A quieter YouTube.").font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                        Text("QuietTube for Safari and Chrome").font(.system(size: 13)).foregroundStyle(QuietTubePalette.secondary)
                    }
                }
                ProtectionCard(model: model)
                VStack(alignment: .leading, spacing: 13) {
                    BrowserRow(model: model, browser: "Safari")
                    Text("Enable QuietTube in Safari’s Extensions settings, then allow it on youtube.com. Reload your video to begin.")
                        .font(.system(size: 12)).foregroundStyle(QuietTubePalette.secondary).lineSpacing(3)
                    Button("Safari settings") { model.safariSettings() }.buttonStyle(QuietTubeButton(primary: true))
                }.padding(18).background(QuietTubePalette.card, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 13) {
                    BrowserRow(model: model, browser: "Chrome")
                    Text("Connect the companion, then open Chrome’s Extensions page. Enable Developer mode and use Load unpacked to select the extension folder.")
                        .font(.system(size: 12)).foregroundStyle(QuietTubePalette.secondary).lineSpacing(3)
                    HStack(spacing: 8) {
                        Button(model.chromeRegistered ? "Companion connected" : "Connect Chrome") { model.connectChrome() }
                            .buttonStyle(QuietTubeButton(primary: !model.chromeRegistered)).disabled(model.chromeRegistered)
                        Button("Chrome settings") { model.chromeSettings() }.buttonStyle(QuietTubeButton())
                    }
                    Button { model.revealChromeExtension() } label: { Label("Show extension folder & copy path", systemImage: "folder") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(QuietTubePalette.green)
                }.padding(18).background(QuietTubePalette.card, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Launch QuietTube at login", isOn: Binding(get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval }, set: { model.launchAtLogin($0) }))
                        .toggleStyle(.switch).font(.system(size: 13)).tint(QuietTubePalette.green)
                    HStack {
                        Button("Export diagnostics") { model.exportDiagnostics() }
                        Spacer()
                        Button("Disconnect Chrome") { model.disconnectChrome() }.disabled(!model.chromeRegistered)
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(QuietTubePalette.green)
                }.padding(.horizontal, 2)
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(QuietTubePalette.amber).fixedSize(horizontal: false, vertical: true) }
                Text("QuietTube lives in your menu bar. Protection settings stay synchronized across connected browsers. Only YouTube access is requested.")
                    .font(.system(size: 11)).foregroundStyle(QuietTubePalette.secondary).lineSpacing(3)
                HStack {
                    Text("QuietTube \(BuildConfiguration.version) · Mac preview")
                    Spacer()
                    Link("Source & licenses", destination: URL(string: "https://github.com/ronniekai999/QuietTube")!)
                }.font(.system(size: 10)).foregroundStyle(QuietTubePalette.secondary)
            }.padding(28)
        }.frame(minWidth: 510, maxWidth: .infinity, minHeight: 640)
            .foregroundStyle(Color.white.opacity(0.94)).background(QuietTubePalette.background).preferredColorScheme(.dark)
    }
}
