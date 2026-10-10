// QuietTube for macOS — GPL-3.0-or-later.
import AppKit
import SwiftUI

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: QuietTubeModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var setupWindow: NSWindow?
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = QuietTubeModel()
        model.openSetup = { [weak self] in self?.showSetup() }
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }
        let menu = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu(title: "QuietTube")
        let settingsItem = NSMenuItem(title: "QuietTube settings…", action: #selector(openSetupWindow), keyEquivalent: ",")
        settingsItem.target = self; applicationMenu.addItem(settingsItem); applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit QuietTube", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp; applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu; menu.addItem(applicationItem); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "QuietTube")
            button.image?.isTemplate = true; button.target = self; button.action = #selector(togglePopover)
            button.toolTip = "QuietTube — YouTube protection"
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: QuietTubePanel(model: model))
        model.start()
        // First launch explains the two browser permission steps. Later login
        // launches stay in the menu bar, preserving the user’s chosen setting.
        if !UserDefaults.standard.bool(forKey: "hasOpenedQuietTube") {
            UserDefaults.standard.set(true, forKey: "hasOpenedQuietTube"); showSetup()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSetup(); return false }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            model.refresh(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func openSetupWindow() { showSetup() }
    private func showSetup() {
        popover.performClose(nil)
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 790),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "QuietTube"; window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true; window.backgroundColor = NSColor(red: 21/255, green: 26/255, blue: 25/255, alpha: 1)
            window.contentView = NSHostingView(rootView: QuietTubeSetup(model: model))
            window.minSize = NSSize(width: 510, height: 680); window.center()
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); setupWindow?.makeKeyAndOrderFront(nil)
    }
}
