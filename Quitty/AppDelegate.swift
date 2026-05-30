
//
//  AppDelegate.swift
//  Quitty
//
//  A modern replacement for SwiftQuit, compatible with macOS Tahoe (16+)
//  Automatically quits macOS apps when their last window is closed.
//
//  Uses raw AXObserver APIs directly (no Swindler/AXSwift library dependencies)
//  which broke on macOS Tahoe.
//

import Cocoa
import ServiceManagement
import Sparkle
import Aptabase

// Interceptor for Aptabase network requests to log them in the UI
class AnalyticsNetworkInterceptor: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        if let urlString = request.url?.absoluteString, urlString.contains("aptabase.com"), URLProtocol.property(forKey: "Handled", in: request) == nil {
            return true
        }
        return false
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        let newRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "Handled", in: newRequest)
        
        let urlStr = request.url?.absoluteString ?? "Unknown URL"
        var paramsStr = "None"
        if let body = request.httpBody ?? request.httpBodyStream?.readAllData() {
            paramsStr = String(data: body, encoding: .utf8) ?? "Binary"
        }
        
        Settings.shared.log("🚀 Aptabase Request: \(urlStr)")
        Settings.shared.log("📦 Params: \(paramsStr)")
        
        URLSession.shared.dataTask(with: newRequest as URLRequest) { [weak self] data, response, error in
            if let error = error {
                Settings.shared.log("❌ Aptabase Error: \(error.localizedDescription)")
                self?.client?.urlProtocol(self!, didFailWithError: error)
                return
            }
            if let response = response as? HTTPURLResponse {
                Settings.shared.log("✅ Aptabase Response Code: \(response.statusCode)")
                if let data = data, let responseText = String(data: data, encoding: .utf8), !responseText.isEmpty {
                    Settings.shared.log("📄 Aptabase Result: \(responseText)")
                }
                self?.client?.urlProtocol(self!, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data = data {
                self?.client?.urlProtocol(self!, didLoad: data)
            }
            self?.client?.urlProtocolDidFinishLoading(self!)
        }.resume()
    }
    
    override func stopLoading() {}
}

extension InputStream {
    func readAllData() -> Data {
        self.open()
        defer { self.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while self.hasBytesAvailable {
            let read = self.read(buffer, maxLength: bufferSize)
            if read < 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static func main() {
        // Enforce single instance
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ct106.quitty"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        
        if runningApps.count > 1 {
            // Send notification to existing instance to show its window
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(bundleID + ".ShowMainWindow"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            
            // Activate the existing instance
            if let existingApp = runningApps.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                existingApp.activate(options: .activateIgnoringOtherApps)
            }
            
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    var statusItem: NSStatusItem?
    var settingsWindowController: SettingsWindowController?
    let windowWatcher = WindowWatcher()
    private var watcherStarted = false
    private var purgeTimer: Timer?
    
    // Sparkle updater
    let updaterController: SPUStandardUpdaterController
    
    override init() {
        // Initialize Sparkle
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        URLProtocol.registerClass(AnalyticsNetworkInterceptor.self)
        Settings.shared.log("applicationDidFinishLaunching started")
        
        // Initialize Aptabase if configuration exists
        if let url = Bundle.main.url(forResource: "analytics", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let appKey = config["AptabaseAppKey"] as? String, !appKey.isEmpty {
            
            NSLog("QuittyDebug: Found appKey: \(appKey)")
            Aptabase.shared.initialize(appKey: appKey)
            NSLog("QuittyDebug: Aptabase initialized")
            
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "hasPromptedForAnalytics") {
                let alert = NSAlert()
                alert.messageText = Settings.shared.localizedString("analytics_prompt_title")
                alert.informativeText = Settings.shared.localizedString("analytics_prompt_desc")
                alert.addButton(withTitle: Settings.shared.localizedString("btn_agree"))
                alert.addButton(withTitle: Settings.shared.localizedString("btn_decline"))
                
                let response = alert.runModal()
                Settings.shared.isAnalyticsEnabled = (response == .alertFirstButtonReturn)
                defaults.set(true, forKey: "hasPromptedForAnalytics")
                NSLog("QuittyDebug: analytics prompt answered: \(Settings.shared.isAnalyticsEnabled)")
            }
            
            NSLog("QuittyDebug: isAnalyticsEnabled: \(Settings.shared.isAnalyticsEnabled)")
            if Settings.shared.isAnalyticsEnabled {
                NSLog("QuittyDebug: Tracking app_launched")
                Aptabase.shared.trackEvent("app_launched")
                Aptabase.shared.flush()
                NSLog("QuittyDebug: Flushed Aptabase")
            }
            
            // Kickstart Aptabase polling which might not start if the app doesn't become active (LSUIElement)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            
            // Also explicitly schedule a flush timer just to be safe
            Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
                NSLog("QuittyDebug: Periodic flush timer triggered")
                if Settings.shared.isAnalyticsEnabled {
                    Aptabase.shared.flush()
                }
            }
        } else {
            NSLog("QuittyDebug: analytics.json not found or empty.")
            Settings.shared.log("analytics.json not found or empty. Telemetry disabled.")
        }

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
        // At login, the accessibility system might take a few seconds to load.
        // We retry after a short delay if it initially fails.
        if checkAccessibilityPermissions(silent: true) {
            startWatcher()
        } else {
            Settings.shared.log("Initial accessibility check failed. Retrying in 5s (system startup delay?)...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.checkAccessibilityPermissions(silent: true) == true {
                    Settings.shared.log("Retry success: permissions found!")
                    self?.startWatcher()
                } else if !settings.launchHidden {
                    // Only prompt if we still fail AND we're supposed to show UI
                    self?.checkAccessibilityPermissions(silent: false)
                }
            }
        }

        // Listen for settings updates (like language change) to refresh menu
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsUpdate),
            name: Settings.didUpdateNotification,
            object: nil
        )

        // Listen for internal "ShowMainWindow" signal from other launch attempts
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showSettings),
            name: NSNotification.Name((Bundle.main.bundleIdentifier ?? "com.ct106.quitty") + ".ShowMainWindow"),
            object: nil
        )

        setupDailyPurgeTimer()
        setupDailyUpdateCheck()
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
        menu.delegate = self
        statusItem?.menu = menu

        // Apply visibility from settings
        statusItem?.isVisible = Settings.shared.menubarIconEnabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        // Deduplicate history by bundleID, keeping only the most recent entry
        var seenBundleIDs = Set<String>()
        var history: [TerminationRecord] = []
        for record in FeedbackEngine.shared.history {
            if !seenBundleIDs.contains(record.bundleID) {
                history.append(record)
                seenBundleIDs.insert(record.bundleID)
            }
            if history.count >= 10 { break }
        }
        
        if !history.isEmpty {
            let headerItem = NSMenuItem(title: Settings.shared.localizedString("menu_recently_quit"), action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)

            for record in history {
                let appItem = NSMenuItem(title: record.appName, action: nil, keyEquivalent: "")
                let icon = FeedbackEngine.shared.appIcon(for: record)
                icon.size = NSSize(width: 16, height: 16)
                appItem.image = icon
                
                let submenu = NSMenu()
                
                let reopenItem = NSMenuItem(title: Settings.shared.localizedString("menu_reopen"), action: #selector(reopenApp(_:)), keyEquivalent: "")
                reopenItem.representedObject = record.bundleID
                submenu.addItem(reopenItem)

                let feedbackItem = NSMenuItem(title: Settings.shared.localizedString("menu_feedback_reopen"), action: #selector(feedbackAndReopen(_:)), keyEquivalent: "")
                feedbackItem.representedObject = record.id
                submenu.addItem(feedbackItem)
                
                appItem.submenu = submenu
                menu.addItem(appItem)
            }
            menu.addItem(NSMenuItem.separator())
        }
        
        menu.addItem(NSMenuItem(title: Settings.shared.localizedString("menu_settings"), action: #selector(showSettings), keyEquivalent: ","))
        
        // Add "Check for Updates"
        let checkUpdateItem = NSMenuItem(title: Settings.shared.localizedString("menu_check_updates"), action: #selector(manualCheckForUpdates(_:)), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: Settings.shared.localizedString("menu_quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func feedbackAndReopen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = FeedbackEngine.shared.history.first(where: { $0.id == id }) else { return }
        
        FeedbackEngine.shared.reportFalseQuit(recordID: id)
        
        // Reopen
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.bundleID) {
            NSWorkspace.shared.open(url)
        } else if let path = record.appIconPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc private func reopenApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open(url)
        }
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

    // MARK: - Daily Resource Purge

    private func setupDailyPurgeTimer() {
        purgeTimer?.invalidate()
        
        let calendar = Calendar.current
        let now = Date()
        
        // Target: Midnight (00:00:00)
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 0
        components.minute = 0
        components.second = 0
        
        guard var purgeDate = calendar.date(from: components) else { return }
        
        // If it's already past midnight, schedule for the next day
        if purgeDate <= now {
            purgeDate = calendar.date(byAdding: .day, value: 1, to: purgeDate)!
        }
        
        let interval = purgeDate.timeIntervalSince(now)
        Settings.shared.log("Scheduled daily resource purge at 00:00 (in \(Int(interval/3600))h \(Int(interval.truncatingRemainder(dividingBy: 3600)/60))m)")
        
        purgeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.performDailyPurge()
        }
    }

    private func performDailyPurge() {
        Settings.shared.log("Starting scheduled daily resource purge...")
        
        // 1. Tell the watcher to rebuild everything
        windowWatcher.purgeResources()
        
        // 2. Clear old logs in Settings to free memory
        Settings.shared.logs.removeAll()
        Settings.shared.clearWatcherDiagnostics()
        
        // 3. Suggest to the system to reclaim memory
        autoreleasepool {
            // Swift's autoreleasepool combined with the internal re-scans in WindowWatcher 
            // should be enough to drop major resource handles.
        }
        
        // 4. Schedule for the next day
        setupDailyPurgeTimer()
        
        Settings.shared.log("Daily resource purge completed successfully.")
    }

    // MARK: - Updates

    @objc func manualCheckForUpdates(_ sender: Any?) {
        if Settings.shared.isAnalyticsEnabled {
            Aptabase.shared.trackEvent("check_for_updates", with: ["automatic": "false"])
        }
        updaterController.checkForUpdates(sender)
    }

    private var updateCheckTimer: Timer?

    private func setupDailyUpdateCheck() {
        // Trigger a background check every 24 hours
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Settings.shared.log("Running automatic daily update check")
            if Settings.shared.isAnalyticsEnabled {
                Aptabase.shared.trackEvent("check_for_updates", with: ["automatic": "true"])
            }
            self?.updaterController.updater.checkForUpdatesInBackground()
        }
        
        // Also do an initial check shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            Settings.shared.log("Running initial background update check")
            if Settings.shared.isAnalyticsEnabled {
                Aptabase.shared.trackEvent("check_for_updates", with: ["automatic": "true"])
            }
            self?.updaterController.updater.checkForUpdatesInBackground()
        }
    }
}
