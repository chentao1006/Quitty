
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

        // Show settings on first launch or if not launch-hidden or if not authorized
        let settings = Settings.shared
        let isAuthorized = AXIsProcessTrusted()
        print("launchHidden = \(settings.launchHidden), isAuthorized = \(isAuthorized), menubarIconEnabled = \(settings.menubarIconEnabled)")
        
        if !settings.launchHidden || !isAuthorized {
            Settings.shared.log("Showing settings window (launchHidden: \(settings.launchHidden), authorized: \(isAuthorized))...")
            DispatchQueue.main.async {
                self.showSettings()
            }
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
        let authorized = AXIsProcessTrusted()
        
        // Retry starting watcher if not already started
        if !watcherStarted && authorized {
            Settings.shared.log("Permissions granted! Starting watcher...")
            startWatcher()
        }
        
        // Auto-trigger permission prompt if not authorized and window is visible
        if !authorized && settingsWindowController?.window?.isVisible == true {
            Settings.shared.log("App active but unauthorized. Triggering prompt...")
            checkAccessibilityPermissions(silent: false)
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
            if !silent {
                // Prompt systemic dialog only. macOS shows its own window, 
                // so we don't need a redundant NSAlert.
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
                AXIsProcessTrustedWithOptions(options)
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
        
        // If not authorized, trigger the system prompt after a short delay
        // to ensure it appears ON TOP of our setting window.
        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.checkAccessibilityPermissions(silent: false)
            }
        }
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
