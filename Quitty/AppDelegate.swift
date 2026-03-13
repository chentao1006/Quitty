
//
//  AppDelegate.swift
//  Quitty
//
//  A modern replacement for SwiftQuit, compatible with macOS Sequoia (15+)
//  Automatically quits macOS apps when their last window is closed.
//
//  Uses raw AXObserver APIs directly (no Swindler/AXSwift library dependencies)
//  which broke on macOS Sequoia.
//

import Cocoa
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    var statusItem: NSStatusItem?
    var settingsWindowController: SettingsWindowController?
    let windowWatcher = WindowWatcher()
    private var watcherStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.log("applicationDidFinishLaunching started")

        // Setup menu bar icon first so the app is always visible
        setupMenuBar()
        Settings.shared.log("setupMenuBar done, statusItem.isVisible = \(statusItem?.isVisible ?? false)")

        // Show settings on first launch or if not launch-hidden
        let settings = Settings.shared
        print("launchHidden = \(settings.launchHidden), menubarIconEnabled = \(settings.menubarIconEnabled)")
        if !settings.launchHidden {
            Settings.shared.log("Showing settings window...")
            showSettings()
            Settings.shared.log("showSettings done, window = \(settingsWindowController?.window), isVisible = \(settingsWindowController?.window?.isVisible ?? false)")
        }

        // Check accessibility permissions and start watching
        if checkAccessibilityPermissions() {
            startWatcher()
        }

        // Listen for settings updates (like language change) to refresh menu
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsUpdate),
            name: Settings.didUpdateNotification,
            object: nil
        )
    }

    @objc private func handleSettingsUpdate() {
        setupMenuBar()
        windowWatcher.refreshAllApps()
    }

    func startWatcher() {
        guard !watcherStarted else { return }
        windowWatcher.start()
        watcherStarted = true
        Settings.shared.log("windowWatcher started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowWatcher.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Retry starting watcher if not already started
        if !watcherStarted && AXIsProcessTrusted() {
            Settings.shared.log("Permissions granted! Starting watcher...")
            startWatcher()
        }
        
        // Refresh settings UI to reflect permission changes
        Settings.shared.objectWillChange.send()
    }

    // MARK: - Accessibility Permissions
    private var isShowingPermissionAlert = false

    @objc @discardableResult
    func checkAccessibilityPermissions() -> Bool {
        return checkAccessibilityPermissions(silent: false)
    }

    @discardableResult
    func checkAccessibilityPermissions(silent: Bool = false) -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            if !silent && !isShowingPermissionAlert {
                isShowingPermissionAlert = true
                
                // Prompt systemic dialog if needed
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
                AXIsProcessTrustedWithOptions(options)

                // Show explanatory alert
                let alert = NSAlert()
                alert.messageText = Settings.shared.localizedString("alert_perm_title")
                alert.informativeText = Settings.shared.localizedString("alert_perm_msg")
                alert.alertStyle = .warning
                alert.addButton(withTitle: Settings.shared.localizedString("btn_open_settings"))
                alert.addButton(withTitle: Settings.shared.localizedString("btn_ignore"))

                // Determine context: sheet or modal
                let targetWindow = settingsWindowController?.window
                if let window = targetWindow, window.isVisible {
                    alert.beginSheetModal(for: window) { [weak self] response in
                        self?.isShowingPermissionAlert = false
                        if response == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                } else {
                    // Using runModal() on the main thread during startup causes a hang.
                    // Instead, we use a small delay or ensure it's not blocking applicationDidFinishLaunching.
                    DispatchQueue.main.async {
                        let response = alert.runModal()
                        self.isShowingPermissionAlert = false
                        if response == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            return false
        }
        return true
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        
        if let button = statusItem?.button {
            button.title = "" // Only icon in menu bar
            
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .light)
            if let image = NSImage(systemSymbolName: "xmark.app", accessibilityDescription: "Quitty")?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                button.image = image
            }
        }

        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: Settings.shared.localizedString("app_name"), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: Settings.shared.localizedString("menu_settings"), action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: Settings.shared.localizedString("menu_quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Apply visibility from settings
        statusItem?.isVisible = Settings.shared.menubarIconEnabled
    }

    // MARK: - Settings Window

    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(self)
    }

    func hideMenuBarIcon() {
        statusItem?.isVisible = false
    }

    func showMenuBarIcon() {
        statusItem?.isVisible = true
    }

    // MARK: - Diagnostic & Relaunch

    func checkHealthAndFix() -> String {
        // 1. Check Permissions
        if !AXIsProcessTrusted() {
            return Settings.shared.localizedString("status_unauthorized")
        }

        // 2. Check if engine is actually holding any observers
        let runningApps = NSWorkspace.shared.runningApplications.filter { 
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier 
        }
        
        // Basic re-sync
        windowWatcher.refreshAllApps()
        
        // If we have multiple apps running but 0 observers, that's a bad sign (API might be stuck)
        if runningApps.count >= 2 && windowWatcher.observerCount == 0 {
            return "restart"
        }
        
        return "ok"
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", path]
        task.launch()
        NSApplication.shared.terminate(nil)
    }
}
