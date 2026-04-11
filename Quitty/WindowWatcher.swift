
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
    private var quitGenerations: [pid_t: Int] = [:] // Incremented when a pending quit is cancelled
    private var armedPids: Set<pid_t> = [] // Apps that have (or had) at least one window
    private var lastHookTimes: [pid_t: Date] = [:] // When we started watching this app
    private var lastCheckTimes: [pid_t: Date] = [:] // Anti-spam for checkAndQuit
    private var lastSpaceChangeDate = Date.distantPast
    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "com.quitty.watcher", qos: .userInitiated, attributes: .concurrent)

    var observerCount: Int {
        return observers.count
    }
    
    // Maintenance timer
    private var maintenanceTimer: Timer?

    // MARK: - Public Interface

    func start() {
        setupWorkspaceObservers()
        // Watch all currently running apps, but wait a bit for system to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshAllApps()
        }
        
        // Start a low-frequency backup timer to catch any missed closure events
        DispatchQueue.main.async {
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                autoreleasepool {
                    self?.periodicCheck()
                }
            }
            
            // Maintenance timer for deep cleanup every hour
            self.maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                self?.maintenanceCleanup()
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            // Remove all AX observers
            for (pid, observer) in self.observers {
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
            self.maintenanceTimer?.invalidate()
            self.maintenanceTimer = nil
        }
    }

    /// Performs a deep refresh of all observation state, clearing stale observers
    /// and rebuilding the monitoring tree from scratch.
    func purgeResources() {
        DispatchQueue.main.async {
            Settings.shared.log("Initiating daily deep resource purge...")
            
            // 1. Remove all existing AX observers and sources
            for (pid, observer) in self.observers {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .defaultMode
                )
            }
            self.observers.removeAll()
            self.observerContexts.removeAll()
            
            // 2. Clear all pending terminal tasks
            for (_, item) in self.pendingQuits {
                item.cancel()
            }
            self.pendingQuits.removeAll()
            self.quitGenerations.removeAll()

            // 3. Reset heuristic tracking
            self.armedPids.removeAll()
            self.lastCheckTimes.removeAll()
            self.lastHookTimes.removeAll()
            
            // 4. Force a full workspace re-scan
            autoreleasepool {
                self.refreshAllApps()
            }
            
            Settings.shared.log("Daily resource purge completed. All observers rebuilt.")
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
            
            // 2. Cleanup OLD observers and tracking data for apps that are no longer in workspace
            let pidsInWorkspace = Set(activeApps.map { $0.processIdentifier })
            
            // Aggressively clean tracking structures to prevent long-term memory growth
            let allTrackedPids = Set(self.observers.keys)
                .union(self.armedPids)
                .union(self.lastCheckTimes.keys)
                .union(self.quitGenerations.keys)
                .union(self.lastHookTimes.keys)
                .union(self.pendingQuits.keys)
            
            let pidsToCleanup = allTrackedPids.subtracting(pidsInWorkspace)
            
            for pid in pidsToCleanup {
                self.removeObserverForPid(pid)
                self.armedPids.remove(pid)
                self.lastHookTimes.removeValue(forKey: pid)
                self.lastCheckTimes.removeValue(forKey: pid)
                self.quitGenerations.removeValue(forKey: pid)
            }
            
            // 3. For apps still in workspace, check if they are still relevant
            for pid in Array(self.observers.keys) {
                if let app = NSRunningApplication(processIdentifier: pid),
                   !Settings.shared.isPotentiallyRelevant(bundlePath: app.bundleURL?.path, bundleID: app.bundleIdentifier) {
                    Settings.shared.log("Cleaning up observer for \(app.localizedName ?? "app") - no longer in target list")
                    self.removeObserverForPid(pid)
                    self.lastHookTimes.removeValue(forKey: pid)
                }
            }
        }
    }

    private func maintenanceCleanup() {
        Settings.shared.log("Performing periodic maintenance cleanup...")
        refreshAllApps()
        
        // Trim any hook history older than 12 hours
        let now = Date()
        lastHookTimes = lastHookTimes.filter { now.timeIntervalSince($0.value) < 43200 }
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
        // For newly launched apps, give them a moment to initialize their accessibility tree on Tahoe
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
            self.quitGenerations.removeValue(forKey: pid)
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
            _ = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
            
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
                // Bump the generation so any in-flight background final-check tasks abort
                self.quitGenerations[pid] = (self.quitGenerations[pid] ?? 0) + 1
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

        // Special apps (Electron, Office, etc.) need more time
        let isSpecial = self.isSpecialCareApp(app)
        
        let baseDelay = isClosed ? 0.4 : 0.8
        var totalDelay = baseDelay * (isSpecial ? 2.0 : 1.5)
        
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

        // DEBOUNCE: Don't check the same app too frequently (min 3s between checks)
        if let lastCheck = lastCheckTimes[pid], Date().timeIntervalSince(lastCheck) < 3.0 {
            return
        }
        lastCheckTimes[pid] = Date()

        // Safety: If a space change just happened, wait significantly longer
        if Date().timeIntervalSince(lastSpaceChangeDate) < 2.0 {
            Settings.shared.log("Space transition in progress. Re-scheduling check for \(appName).")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.checkAndQuit(app: app)
            }
            return
        }

        // AX Calls can sometimes block; wrap in autoreleasepool to ensure CF objects are freed
        queue.async { [weak self] in
            autoreleasepool {
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
                
                let isSpecial = self.isSpecialCareApp(app)
                let isAppCurrentlyActive = app.isActive
                // Slightly more responsive delays
                let extraDelay = (isAppCurrentlyActive ? 2.5 : 0.5) + (isSpecial ? 2.0 : 1.0)
                let totalDelay = 1.5 + extraDelay

                // Capture the generation at the time we schedule; if a window appears
                // before the workItem fires it will bump quitGenerations[pid] and the
                // background task will abort.
                let scheduledGeneration = self.quitGenerations[pid] ?? 0
                
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.performFinalCheckAndQuit(pid: pid, appName: appName, generation: scheduledGeneration)
                }

                self.pendingQuits[pid] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay, execute: workItem)
            }
        }
    }
}

    private func performFinalCheckAndQuit(pid: pid_t, appName: String, generation: Int = -1) {
        // Double check app is still alive
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            DispatchQueue.main.async { self.pendingQuits.removeValue(forKey: pid) }
            return
        }

        // Final window count check
        queue.async {
            autoreleasepool {
                // Abort if a new window appeared after we were scheduled (generation mismatch)
                let currentGeneration = DispatchQueue.main.sync { self.quitGenerations[pid] ?? 0 }
                if generation >= 0 && currentGeneration != generation {
                    Settings.shared.log("Final check aborted for \(appName) – window appeared after scheduling.")
                    DispatchQueue.main.async { self.pendingQuits.removeValue(forKey: pid) }
                    return
                }

                // During space transitions, treat ALL apps with maximum caution
                let lockTime = 6.0
                
                if Date().timeIntervalSince(self.lastSpaceChangeDate) < lockTime {
                    Settings.shared.log("Space transition still active. Postponing final check for \(appName).")
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
                    Settings.shared.log("Final check failed to get windows for \(appName). Aborting termination.")
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
                        // Record termination for history + feedback learning
                        FeedbackEngine.shared.recordTermination(
                            pid: pid,
                            bundleID: app.bundleIdentifier ?? "",
                            appName: appName,
                            bundlePath: app.bundleURL?.path
                        )
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
    }

    /// High-reliability window check using the Window Server's direct list.
    private func isActualWindowPresent(pid: pid_t) -> Bool {
        return autoreleasepool {
            let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionAll)
            guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                return true // Safety
            }

        let app = NSRunningApplication(processIdentifier: pid)
        let isSpecial = app.map { isSpecialCareApp($0) } ?? false
        let appName = (app?.localizedName ?? "").lowercased()
        let bundleID = (app?.bundleIdentifier ?? "").lowercased()
        // Certain apps are known for persistent unnamed ghosts (hard-coded baseline)
        let isGhostProneHardcoded = appName.contains("handbrake") || appName.contains("termora") ||
                           bundleID.contains("handbrake") || bundleID.contains("termora")
        // Also check learned override from user feedback
        let isGhostProneLearned = FeedbackEngine.shared.isGhostProneOverride(bundleID: app?.bundleIdentifier ?? bundleID)
        let isGhostProne = isGhostProneHardcoded || isGhostProneLearned
        // Sensitivity multiplier from feedback: 
        // >1.0 means ignore MORE stuff (due to Failed Quit feedback)
        // <1.0 means keep MORE stuff (due to False Quit feedback)
        let sensitivityMult = FeedbackEngine.shared.sensitivityMultiplier(bundleID: app?.bundleIdentifier ?? bundleID)
        let cautionMult = sensitivityMult > 0 ? 1.0 / sensitivityMult : 1.0

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
            
            // Hardcoded minimum 40x40; drops to 20x20 if we've had many False Quits
            let minDim: CGFloat = sensitivityMult < 0.6 ? 20 : 40
            if width <= minDim || height <= minDim { continue }

            let name = window[kCGWindowName as String] as? String ?? ""
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Ignore system proxies
            if ["Touch Bar", "Focus Proxy", "Item Status", "Emoji & Symbols", "FocusProxy"].contains(trimmedName) {
                continue
            }
            
            if !trimmedName.isEmpty { return true }
            
            // UNNAMED WINDOW LOGIC (Common in Electron, Java, Flutter, Terminals, etc.)
            
            // Absolute minimum size for an unnamed window; adjusted by user feedback.
            // A multiplier > 1.0 means we ignore LARGER windows (more aggressive quitting).
            if width < (80 * sensitivityMult) || height < (80 * sensitivityMult) { 
                continue 
            }
            
            // Universal Ghost Sizes (known non-visible windows from various apps)
            let isGhostSize = (abs(width - 500) < 30 && abs(height - 500) < 30) || 
                              (abs(width - 600) < 30 && abs(height - 600) < 30) ||
                              (abs(width - 692) < 25 && abs(height - 413) < 25) ||
                              (abs(width - 715) < 30 && abs(height - 364) < 30) || // Screen Sharing ghost
                              (abs(width - 735) < 30 && abs(height - 424) < 30) || // Sequel Ace ghost
                              (abs(width - 885) < 15 && abs(height - 670) < 15) || // HandBrake ghost
                              (abs(width - 844) < 15 && abs(height - 457) < 15) || // Windows App ghost
                              (abs(width - 360) < 15 && abs(height - 380) < 15) || // Termora ghost
                              (abs(width - 550) < 30 && abs(height - 420) < 50) || // Termora ghost var 1
                              (abs(width - 960) < 60 && abs(height - 660) < 60) ||
                              (abs(width - 1040) < 20 && abs(height - 1040) < 20) ||
                              (abs(width - 1291) < 20 && abs(height - 832) < 20) // Microsoft Excel ghost
            
            // Also check dynamically learned ghost sizes from user feedback
            let learnedGhost = FeedbackEngine.shared.isLearnedGhostSize(
                bundleID: app?.bundleIdentifier ?? bundleID,
                width: width, height: height
            )

            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false

            // If it matches a universal ghost size:
            if !learnedGhost && isGhostSize {
                // We only allow "False Quit" feedback to override universal ghosts IF the window is ONSCREEN.
                // If it's on another space (off-screen), we continue to treat it as a ghost to avoid "Can't Quit" loops.
                if sensitivityMult < 0.75 && isOnScreen {
                    Settings.shared.log("   -> Universal ghost size (\(Int(width))x\(Int(height))) considered POSSIBLY REAL due to False Quit reports.")
                } else {
                    continue // Trust the universal ghost list (especially if off-screen)
                }
            } else if learnedGhost {
                // If the user has reported "False Quit" multiple times, we stop trusting even learned ghosts
                // but ONLY if they are ONSCREEN.
                if sensitivityMult < 0.5 && isOnScreen {
                    Settings.shared.log("   -> Learned ghost size (\(Int(width))x\(Int(height))) RECLAIMED as real due to repeated False Quits.")
                } else {
                    continue // Always trust user-learned ghosts
                }
            }
            
            if !isOnScreen {
                // Window on another space
                // Ultra-conservative threshold for unnamed windows on other spaces.
                var threshold: CGFloat = isSpecial ? 150 : 250
                if isGhostProne {
                    threshold = 400
                }
                // Apply learned caution multiplier (scales threshold down = easier to be real)
                threshold = threshold / cautionMult
                
                if width > threshold && height > threshold {
                    Settings.shared.log("   -> [isActualWindowPresent] Found window for \(pid) on another space (\(Int(width))x\(Int(height)))")
                    return true
                }
            } else {
                // Onscreen unnamed window
                // Even more conservative for onscreen unnamed windows.
                var threshold: CGFloat = isSpecial ? 120 : 250
                threshold = threshold / cautionMult
                if width > threshold && height > threshold {
                    Settings.shared.log("   -> [isActualWindowPresent] Found unnamed onscreen window for \(pid) (\(Int(width))x\(Int(height)))")
                    return true
                }
                continue
            }
        }
        return false
      }
    }

    private func isSpecialCareApp(_ app: NSRunningApplication) -> Bool {
        let appName = (app.localizedName ?? "").lowercased()
        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        
        // Keywords for apps that use cross-platform frameworks (Electron, Java, etc.),
        // terminal emulators, or heavy native apps with ghost windows (Office).
        // These often have unnamed windows, non-standard AX trees, or slow updates.
        let specialKeywords = [
            "vscode", "visualstudio", "antigravity", "electron", "discord", 
            "slack", "cursor", "obsidian", "linear", "notion", "term", 
            "java", "jetbrains", "intellij", "warp", "termora", "tabby", 
            "wezterm", "alacritty", "microsoft", "excel", "powerpoint", "outlook", "word",
            "handbrake", "windows app", "sharing", "screensharing"
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
