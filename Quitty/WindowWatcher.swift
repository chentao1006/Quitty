
//
//  WindowWatcher.swift
//  Quitty
//
//  The core engine that monitors window events across all running apps.
//

import Cocoa
import ApplicationServices

// These Accessibility constants are defined as C CFSTR() macros in the HIServices
// headers but don't bridge to Swift automatically. We define them here.
private let kAXWindowClosedNotification = "AXWindowClosed" as CFString
private let kAXWindowCreatedNotification = "AXWindowCreated" as CFString
private let kAXSheetSubrole = "AXSheet"
private let kAXDrawerSubrole = "AXDrawer"

private class ObserverContext {
    let watcher: WindowWatcher
    let pid: pid_t
    init(watcher: WindowWatcher, pid: pid_t) {
        self.watcher = watcher
        self.pid = pid
    }
}

class WindowWatcher {

    // One AXObserver per running app PID - ALWAYS access on Main Thread
    private var observers: [pid_t: AXObserver] = [:]
    private var observerContexts: [pid_t: ObserverContext] = [:]
    private var pendingQuits: [pid_t: DispatchWorkItem] = [:]
    private var armedPids: Set<pid_t> = [] // Apps that have (or had) at least one window
    private var lastHookTimes: [pid_t: Date] = [:] // When we started watching this app
    private var lastCheckTimes: [pid_t: Date] = [:] // Anti-spam for checkAndQuit
    private var lastSpaceChangeDate = Date.distantPast
    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "com.quitty.watcher", qos: .userInitiated, attributes: .concurrent)

    var observerCount: Int {
        return observers.count
    }

    // MARK: - Public Interface

    func start() {
        setupWorkspaceObservers()
        // Watch all currently running apps, but wait a bit for system to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshAllApps()
        }
        
        // Start a low-frequency backup timer to catch any missed closure events
        DispatchQueue.main.async {
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
                self?.periodicCheck()
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            // Remove all AX observers
            for (pid, observer) in self.observers {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    self.removeObserver(observer, for: app)
                }
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .defaultMode
                )
            }
            self.observers.removeAll()
            self.observerContexts.removeAll()
            for (_, item) in self.pendingQuits {
                item.cancel()
            }
            self.pendingQuits.removeAll()

            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
        }
    }

    func refreshAllApps() {
        DispatchQueue.main.async {
            let activeApps = NSWorkspace.shared.runningApplications
            
            // 1. Hook NEW apps that are now relevant
            for app in activeApps {
                // Use a slight delay even for existing apps to ensure stability on startup
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.watchApp(app)
                }
            }
            
            // 2. Cleanup OLD observers for apps that are no longer relevant (e.g. settings changed)
            let pidsInWorkspace = Set(activeApps.map { $0.processIdentifier })
            for pid in Array(self.observers.keys) {
                // If app is gone entirely, appTerminated usually handles it, but let's be double sure
                if !pidsInWorkspace.contains(pid) {
                    self.removeObserverForPid(pid)
                    self.lastHookTimes.removeValue(forKey: pid)
                    continue
                }
                
                // If app is still running but should no longer be watched
                if let app = NSRunningApplication(processIdentifier: pid),
                   !Settings.shared.isPotentiallyRelevant(bundlePath: app.bundleURL?.path, bundleID: app.bundleIdentifier) {
                    Settings.shared.log("Cleaning up observer for \(app.localizedName ?? "app") - no longer in target list")
                    self.removeObserverForPid(pid)
                    self.lastHookTimes.removeValue(forKey: pid)
                }
            }
        }
    }

    private func removeObserverForPid(_ pid: pid_t) {
        if let observer = self.observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        self.observerContexts.removeValue(forKey: pid)
        self.pendingQuits[pid]?.cancel()
        self.pendingQuits.removeValue(forKey: pid)
    }

    private func periodicCheck() {
        let activeApps = NSWorkspace.shared.runningApplications
        for app in activeApps {
            guard Settings.shared.isPotentiallyRelevant(bundlePath: app.bundleURL?.path, bundleID: app.bundleIdentifier) else { continue }
            
            // Only periodically check apps we are already watching and that are NOT active
            let pid = app.processIdentifier
            if observers[pid] != nil && !app.isActive && !app.isHidden {
                // If it's been armed at some point but currently reports 0 windows, trigger a check
                if armedPids.contains(pid) {
                    self.checkAndQuit(app: app)
                }
            }
        }
    }

    // MARK: - NSWorkspace Notifications

    private func setupWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func spaceChanged() {
        lastSpaceChangeDate = Date()
        Settings.shared.log("Space change detected. Postponing window checks.")
    }

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // For newly launched apps, give them a moment to initialize their accessibility tree on Sequoia
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.watchApp(app)
        }
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        
        DispatchQueue.main.async {
            // Remove from observers and cleanup
            if let observer = self.observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .defaultMode
                )
                Settings.shared.log("Cleaned up observer for terminated PID: \(pid)")
            }
            
            self.observerContexts.removeValue(forKey: pid)
            self.armedPids.remove(pid)
            self.lastHookTimes.removeValue(forKey: pid)
            self.lastCheckTimes.removeValue(forKey: pid)
            self.pendingQuits[pid]?.cancel()
            self.pendingQuits.removeValue(forKey: pid)
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        // When an app is activated, try to watch it if we haven't already
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        DispatchQueue.main.async { [weak self] in
            self?.watchApp(app)
        }
    }

    // MARK: - AXObserver Setup

    private func watchApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let bundlePath = app.bundleURL?.path
        let appName = app.localizedName ?? "Unknown"
        
        // Skip if already being watched or if it's our own process
        guard observers[pid] == nil else { return }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        
        // Regular and accessory apps only
        guard app.activationPolicy == .regular || app.activationPolicy == .accessory else { return }
        
        // Avoid watching terminated apps
        guard !app.isTerminated else { return }

        // ONLY watch apps that we are supposed to handle to save resources and avoid noise
        if !Settings.shared.isPotentiallyRelevant(bundlePath: bundlePath, bundleID: bundleID) {
            return
        }

        Settings.shared.log("Attempting to watch Target App: \(appName) (PID: \(pid))")

        // Initial check: if app already has windows, arm it immediately
        checkInitialWindows(pid: pid)

        // Create AX element for the target app
        let axApp = AXUIElementCreateApplication(pid)

        // Create an AXObserver with callback context
        var observer: AXObserver?
        let context = ObserverContext(watcher: self, pid: pid)
        self.observerContexts[pid] = context
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()

        let err = AXObserverCreate(pid, { (observer, element, notification, userData) in
            guard let userData = userData else { return }
            let ctx = Unmanaged<ObserverContext>.fromOpaque(userData).takeUnretainedValue()
            let notificationName = notification as String
            
            ctx.watcher.handleAXNotification(element: element, notification: notificationName, pid: ctx.pid)
        }, &observer)

        guard err == .success, let obs = observer else {
            if err == .apiDisabled {
                Settings.shared.log("ERROR - Accessibility API disabled while watching \(appName).")
            } else {
                Settings.shared.log("Failed to create AXObserver for \(appName) (PID: \(pid)): \(err.rawValue)")
            }
            // Cleanup context if failed
            self.observerContexts.removeValue(forKey: pid)
            return
        }

        // Subscribe to events
        let n1 = AXObserverAddNotification(obs, axApp, kAXWindowClosedNotification, contextPtr)
        let n2 = AXObserverAddNotification(obs, axApp, kAXWindowCreatedNotification, contextPtr)
        let n3 = AXObserverAddNotification(obs, axApp, kAXUIElementDestroyedNotification as CFString, contextPtr)

        if n1 != .success || n2 != .success || n3 != .success {
            Settings.shared.log("Warning: Failed to subscribe to notifications for \(appName): \(n1.rawValue), \(n2.rawValue), \(n3.rawValue)")
            
            // If primary notifications (created/closed) failed, don't keep this observer.
            if n1 != .success || n2 != .success {
                Settings.shared.log("Critical subscriptions failed for \(appName). Abandoning observer.")
                self.observerContexts.removeValue(forKey: pid)
                return
            }
        }

        // Add to main run loop
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        observers[pid] = obs
        lastHookTimes[pid] = Date()
        Settings.shared.log("--- Currently watching: \(appName) ---")
    }


    private func removeObserver(_ observer: AXObserver, for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXObserverRemoveNotification(observer, axApp, kAXWindowClosedNotification as CFString)
        AXObserverRemoveNotification(observer, axApp, kAXWindowCreatedNotification as CFString)
        AXObserverRemoveNotification(observer, axApp, kAXUIElementDestroyedNotification as CFString)
    }

    private func checkInitialWindows(pid: pid_t, retries: Int = 2) {
        // Give the app a bit of time to settle AX tree
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            let axApp = AXUIElementCreateApplication(pid)
            var windows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
            
            let list = windows as? [AXUIElement] ?? []
            let validWindows = list.filter { window in
                var subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                let sub = subrole as? String ?? ""
                return sub != kAXSheetSubrole && sub != kAXDrawerSubrole
            }

            if !validWindows.isEmpty {
                DispatchQueue.main.async {
                    self.armedPids.insert(pid)
                }
            } else if retries > 0 {
                // If no windows found, try again shortly. This is crucial for apps 
                // that are still initializing their AX tree when we hook them.
                self.checkInitialWindows(pid: pid, retries: retries - 1)
            }
        }
    }

    // MARK: - Window Closed Event Handler

    private func handleAXNotification(element: AXUIElement, notification: String, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { 
            return 
        }

        if notification == (kAXWindowCreatedNotification as String) {
            Settings.shared.log("Window created for \(app.localizedName ?? "app"). Arming and cancelling pending quit.")
            DispatchQueue.main.async {
                self.armedPids.insert(pid)
                self.pendingQuits[pid]?.cancel()
                self.pendingQuits.removeValue(forKey: pid)
            }
            return
        }
        
        // Window closed or element destroyed
        let isClosed = notification == (kAXWindowClosedNotification as String)
        let isDestroyed = notification == (kAXUIElementDestroyedNotification as String)
        guard isClosed || isDestroyed else { return }

        // STABILITY PROTECTION:
        // 1. Hook grace period (ignore noise during first 1.5s)
        if let hookTime = lastHookTimes[pid], Date().timeIntervalSince(hookTime) < 1.5 {
            return 
        }

        // 2. Space change grace period (ignore noise for 1.5s after space change)
        if Date().timeIntervalSince(lastSpaceChangeDate) < 1.5 {
            Settings.shared.log("Ignoring \(notification) for \(app.localizedName ?? "app") during space transition noise.")
            return
        }

        Settings.shared.log("Received \(notification) for \(app.localizedName ?? "app") (PID: \(pid))")

        // Electron-based apps need more time
        let isElectron = self.isElectronApp(app)
        
        let baseDelay = isClosed ? 0.4 : 0.8
        var totalDelay = baseDelay * (isElectron ? 2.0 : 1.5)
        
        // Grace period during space change is now generous for ALL apps
        if Date().timeIntervalSince(lastSpaceChangeDate) < 5.0 {
            totalDelay = 15.0 
            Settings.shared.log("Deferring check for \(app.localizedName ?? "app") due to recent space transition.")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) { [weak self] in
            self?.checkAndQuit(app: app)
        }
    }

    // MARK: - Quit Logic

    private func checkAndQuit(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        
        guard !app.isTerminated else { return }
        
        // Safety: Do not quit applications that are hidden (Cmd+H)
        if app.isHidden {
            return
        }
        // Safety: only quit apps that have opened at least one window during this session
        guard armedPids.contains(pid) else {
            return
        }

        // DEBOUNCE: Don't check the same app too frequently
        lastCheckTimes[pid] = Date()

        // Safety: If a space change just happened, wait significantly longer
        if Date().timeIntervalSince(lastSpaceChangeDate) < 2.0 {
            // Anti-spam: only log once every 2 seconds per app
            if Date().timeIntervalSince(lastCheckTimes[pid] ?? .distantPast) > 2.0 {
                Settings.shared.log("Space transition in progress. Re-scheduling check for \(appName).")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.checkAndQuit(app: app)
            }
            return
        }

        // AX Calls can sometimes block
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Get window list using Accessibility API
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

            var windowCount = 0
            if err == .success, let windows = windowsRef as? [AXUIElement] {
                windowCount = windows.filter { window in
                    var subrole: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                    let sub = subrole as? String ?? ""
                    return sub != kAXSheetSubrole && sub != kAXDrawerSubrole
                }.count
            } else if err != .success && err != .noValue {
                Settings.shared.log("Warning - Failed to get windows for \(appName): \(err.rawValue)")
                return // Safety: don't quit if we can't be sure
            }

            if windowCount > 0 {
                DispatchQueue.main.async {
                    self.pendingQuits[pid]?.cancel()
                    self.pendingQuits.removeValue(forKey: pid)
                }
                return
            }

            // Check settings
            guard let bundlePath = app.bundleURL?.path else { return }
            let bundleID = app.bundleIdentifier
            if !Settings.shared.shouldQuitApp(bundlePath: bundlePath, bundleID: bundleID) {
                return
            }

            // Final check on Main Thread to schedule termination
            DispatchQueue.main.async {
                self.pendingQuits[pid]?.cancel()
                
                let isElectron = self.isElectronApp(app)
                let isAppCurrentlyActive = app.isActive
                // Slightly more responsive delays
                let extraDelay = (isAppCurrentlyActive ? 2.5 : 0.5) + (isElectron ? 2.0 : 1.0)
                let totalDelay = 1.5 + extraDelay
                
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.performFinalCheckAndQuit(pid: pid, appName: appName)
                }

                self.pendingQuits[pid] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay, execute: workItem)
            }
        }
    }

    private func performFinalCheckAndQuit(pid: pid_t, appName: String) {
        // Double check app is still alive
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            self.pendingQuits.removeValue(forKey: pid)
            return
        }

        // Final window count check
        queue.async {
            // During space transitions, treat ALL apps with maximum caution
            let lockTime = 12.0
            
            if Date().timeIntervalSince(self.lastSpaceChangeDate) < lockTime {
                Settings.shared.log("Space transition still active (\(Int(12.0 - Date().timeIntervalSince(self.lastSpaceChangeDate)))s remaining). Postponing final check for \(appName).")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    guard let self = self, let app = NSRunningApplication(processIdentifier: pid) else { return }
                    self.pendingQuits.removeValue(forKey: pid)
                    self.checkAndQuit(app: app)
                }
                return
            }

            let axApp = AXUIElementCreateApplication(pid)
            var windows: CFTypeRef?
            let res = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
            
            if res != .success && res != .noValue {
                Settings.shared.log("Final check failed to get windows for \(appName): \(res.rawValue). Aborting termination.")
                DispatchQueue.main.async {
                    self.pendingQuits.removeValue(forKey: pid)
                }
                return
            }

            let foundWindows = windows as? [AXUIElement] ?? []
            let count = foundWindows.filter { win in
                var sub: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &sub)
                let s = sub as? String ?? ""
                return s != kAXSheetSubrole && s != kAXDrawerSubrole
            }.count
            
            if count == 0 {
                // LAST STAND: Cross-verify with low-level CGWindowList.
                if self.isActualWindowPresent(pid: pid) {
                    Settings.shared.log("AX reported 0 but CGWindowList found windows for \(appName). Aborting.")
                    DispatchQueue.main.async {
                        self.pendingQuits.removeValue(forKey: pid)
                    }
                    return
                }

                Settings.shared.log("Final check confirmed 0 windows for \(appName). Terminating.")
                DispatchQueue.main.async {
                    app.terminate()
                    self.pendingQuits.removeValue(forKey: pid)
                }
            } else {
                Settings.shared.log("Final check skipped for \(appName) (Windows found: \(count))")
                DispatchQueue.main.async {
                    self.pendingQuits.removeValue(forKey: pid)
                }
            }
        }
    }

    /// High-reliability window check using the Window Server's direct list.
    private func isActualWindowPresent(pid: pid_t) -> Bool {
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return true // Safety
        }

        let isElectron = NSRunningApplication(processIdentifier: pid).map { isElectronApp($0) } ?? false

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { continue }
            
            // Layer check: Most standard windows are Layer 0.
            // We allow up to Layer 100 to catch specialized UI/Terminal windows and cross-platform toolkits.
            guard let layer = window[kCGWindowLayer as String] as? Int, (0...100).contains(layer) else { continue }
            
            // Alpha check
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
            
            // Size check
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = bounds?["Width"] as? CGFloat ?? 0
            let height = bounds?["Height"] as? CGFloat ?? 0

            if alpha < 0.01 { continue }
            if width <= 40 || height <= 40 { continue }

            let name = window[kCGWindowName as String] as? String ?? ""
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Ignore system proxies
            if ["Touch Bar", "Focus Proxy", "Item Status", "Emoji & Symbols", "FocusProxy"].contains(trimmedName) {
                continue
            }
            
            if !trimmedName.isEmpty { return true }
            
            // UNNAMED WINDOW LOGIC (Common in Electron, Java, Flutter, Terminals, etc.)
            
            // Absolute minimum size for an unnamed window to be considered potentially real.
            // Lowered to 80x80 to catch smaller Terminal windows while avoiding micro-artifacts.
            if width < 80 || height < 80 { continue }
            
            // Universal Ghost Sizes (known non-visible windows from various apps)
            let isGhostSize = (abs(width - 500) < 30 && abs(height - 500) < 30) || 
                              (abs(width - 600) < 30 && abs(height - 600) < 30) ||
                              (abs(width - 692) < 25 && abs(height - 413) < 25) ||
                              (abs(width - 715) < 30 && abs(height - 364) < 30) || // Screen Sharing ghost
                              (abs(width - 735) < 30 && abs(height - 424) < 30) || // Sequel Ace ghost
                              (abs(width - 960) < 60 && abs(height - 660) < 60) ||
                              (abs(width - 1040) < 20 && abs(height - 1040) < 20)
            
            if isGhostSize { continue }
            
            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !isOnScreen {
                // Window on another space
                // Relaxed threshold (110x110) for cross-platform/special apps.
                let threshold: CGFloat = isElectron ? 110 : 250
                if width > threshold && height > threshold {
                    Settings.shared.log("   -> [isActualWindowPresent] Found window for \(pid) on another space (\(Int(width))x\(Int(height)))")
                    return true
                }
            } else {
                // Onscreen unnamed window
                // Relaxed threshold (180x180) for cross-platform/special apps.
                let threshold: CGFloat = isElectron ? 180 : 350
                if width > threshold && height > threshold {
                    Settings.shared.log("   -> [isActualWindowPresent] Found unnamed onscreen window for \(pid) (\(Int(width))x\(Int(height)))")
                    return true
                }
                continue
            }
        }
        return false
    }

    private func isElectronApp(_ app: NSRunningApplication) -> Bool {
        let appName = (app.localizedName ?? "").lowercased()
        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        
        // Keywords for apps that use cross-platform frameworks (Electron, Java, etc.)
        // or terminal emulators. These often have unnamed windows or non-standard AX trees.
        let specialKeywords = [
            "vscode", "visualstudio", "antigravity", "electron", "discord", 
            "slack", "cursor", "obsidian", "linear", "notion", "term", 
            "java", "jetbrains", "intellij", "warp", "termora", "tabby", 
            "wezterm", "alacritty"
        ]
        
        if specialKeywords.contains(where: { bundleID.contains($0) || appName.contains($0) }) {
            return true
        }
        
        if let path = app.bundleURL?.path.lowercased(), path.contains("electron") {
            return true
        }
        return false
    }
}

// Helper to get pid from AXUIElement
private func AXUIElementGetPid(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}
