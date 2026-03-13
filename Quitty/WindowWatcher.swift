
//
//  WindowWatcher.swift
//  Quitty
//
//  The core engine that monitors window events across all running apps.
//
//  APPROACH (macOS Sequoia compatible):
//  - Uses NSWorkspace notifications to track app launches/terminations
//  - For each running app, creates a raw AXObserver watching for
//    kAXWindowClosedNotification (no Swindler/AXSwift library needed)
//  - When a window closes, checks if the app has any remaining windows
//  - If no windows remain, terminates the app after the configured delay
//
//  This approach works on macOS Sequoia+ because:
//  1. We use the raw C Accessibility API (AXObserver) directly
//  2. We don't depend on Swindler which relies on broken internal APIs
//  3. We use NSWorkspace for reliable app lifecycle tracking
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
    private let queue = DispatchQueue(label: "com.quitty.watcher", qos: .userInitiated, attributes: .concurrent)

    var observerCount: Int {
        return observers.count
    }

    // MARK: - Public Interface

    func start() {
        setupWorkspaceObservers()
        // Watch all currently running apps
        refreshAllApps()
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
        }
    }

    func refreshAllApps() {
        DispatchQueue.main.async {
            let activeApps = NSWorkspace.shared.runningApplications
            
            // 1. Hook NEW apps that are now relevant
            for app in activeApps {
                self.watchApp(app)
            }
            
            // 2. Cleanup OLD observers for apps that are no longer relevant (e.g. settings changed)
            let pidsInWorkspace = Set(activeApps.map { $0.processIdentifier })
            for pid in Array(self.observers.keys) {
                // If app is gone entirely, appTerminated usually handles it, but let's be double sure
                if !pidsInWorkspace.contains(pid) {
                    self.removeObserverForPid(pid)
                    continue
                }
                
                // If app is still running but should no longer be watched
                if let app = NSRunningApplication(processIdentifier: pid),
                   !Settings.shared.isPotentiallyRelevant(bundlePath: app.bundleURL?.path, bundleID: app.bundleIdentifier) {
                    Settings.shared.log("Cleaning up observer for \(app.localizedName ?? "app") - no longer in target list")
                    self.removeObserverForPid(pid)
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
            Settings.shared.log("Warning: Failed to subscribe to some notifications for \(appName): \(n1.rawValue), \(n2.rawValue), \(n3.rawValue)")
            
            // If primary notifications (created/closed) failed, don't keep this observer.
            // This allows us to retry later.
            if n1 != .success || n2 != .success {
                Settings.shared.log("Critical subscriptions failed for \(appName). Abandoning observer for retry.")
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
        Settings.shared.log("--- Currently watching: \(appName) ---")
    }


    private func removeObserver(_ observer: AXObserver, for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXObserverRemoveNotification(observer, axApp, kAXWindowClosedNotification as CFString)
        AXObserverRemoveNotification(observer, axApp, kAXWindowCreatedNotification as CFString)
        AXObserverRemoveNotification(observer, axApp, kAXUIElementDestroyedNotification as CFString)
    }

    // MARK: - Window Closed Event Handler

    private func handleAXNotification(element: AXUIElement, notification: String, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { 
            Settings.shared.log("Received \(notification) but could not find app for PID: \(pid)")
            return 
        }

        Settings.shared.log("Received \(notification) for \(app.localizedName ?? "app") (PID: \(pid))")

        if notification == (kAXWindowCreatedNotification as String) {
            Settings.shared.log("Window created for \(app.localizedName ?? "app"). Cancelling pending quit.")
            DispatchQueue.main.async {
                self.pendingQuits[pid]?.cancel()
                self.pendingQuits.removeValue(forKey: pid)
            }
            return
        }

        // For closed/destroyed events, check if we should quit
        // Delay slightly to let the application update its window list internal state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.checkAndQuit(app: app)
        }
    }

    // MARK: - Quit Logic

    private func checkAndQuit(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        
        guard !app.isTerminated else { return }

        // AX Calls can sometimes block if an app is beachballing, but we must use background carefully
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
                
                let delay = Settings.shared.closeDelay
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.performFinalCheckAndQuit(pid: pid, appName: appName)
                }

                self.pendingQuits[pid] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }
    }

    private func performFinalCheckAndQuit(pid: pid_t, appName: String) {
        // Double check app is still alive
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            self.pendingQuits.removeValue(forKey: pid)
            return
        }

        // Final window count check on background queue to avoid freezing Quitty
        queue.async {
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

            let count = (windows as? [AXUIElement])?.filter { win in
                var sub: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &sub)
                let s = sub as? String ?? ""
                return s != kAXSheetSubrole && s != kAXDrawerSubrole
            }.count ?? 0
            
            if count == 0 {
                Settings.shared.log("Final check confirmed 0 windows for \(appName). Terminating.")
                DispatchQueue.main.async {
                    app.terminate()
                    self.pendingQuits.removeValue(forKey: pid)
                }
            } else {
                Settings.shared.log("Final check skipped termination for \(appName) (Window count: \(count))")
                DispatchQueue.main.async {
                    self.pendingQuits.removeValue(forKey: pid)
                }
            }
        }
    }
}

// Helper to get pid from AXUIElement
private func AXUIElementGetPid(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}
