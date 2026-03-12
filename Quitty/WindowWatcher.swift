
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

class WindowWatcher {

    // One AXObserver per running app PID - ALWAYS access on Main Thread
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingQuits: [pid_t: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.quitty.watcher", qos: .userInitiated)

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
            for app in NSWorkspace.shared.runningApplications {
                self.watchApp(app)
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
    }

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // For newly launched apps, give them a moment to initialize their accessibility tree on Sequoia
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
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
                print("Quitty: Cleaned up observer for terminated PID: \(pid)")
            }
            
            self.pendingQuits[pid]?.cancel()
            self.pendingQuits.removeValue(forKey: pid)
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        // When an app is activated, try to watch it if we haven't already
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        watchApp(app)
    }

    // MARK: - AXObserver Setup

    private func watchApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        
        // Skip if already being watched or if it's our own process
        guard observers[pid] == nil else { return }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        
        // Regular and accessory apps only
        guard app.activationPolicy == .regular || app.activationPolicy == .accessory else { return }
        
        // Avoid watching terminated apps
        guard !app.isTerminated else { return }

        print("Quitty: Attempting to watch: \(app.localizedName ?? "Unknown") (PID: \(pid))")

        // Create AX element for the target app
        let axApp = AXUIElementCreateApplication(pid)

        // Create an AXObserver with callback
        var observer: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let err = AXObserverCreate(pid, { (observer, element, notification, userData) in
            guard let userData = userData else { return }
            let watcher = Unmanaged<WindowWatcher>.fromOpaque(userData).takeUnretainedValue()
            let notificationName = notification as String
            
            // Re-fetch PID safely inside callback to be sure
            var elementPid: pid_t = 0
            AXUIElementGetPid(element, &elementPid)
            
            watcher.handleAXNotification(element: element, notification: notificationName, pid: elementPid)
        }, &observer)

        guard err == .success, let obs = observer else {
            if err == .apiDisabled {
                print("Quitty: ERROR - Accessibility API disabled. Please check permissions.")
            } else {
                print("Quitty: Failed to create AXObserver for PID \(pid): \(err.rawValue)")
            }
            return
        }

        // Subscribe to window closed and created events
        AXObserverAddNotification(obs, axApp, kAXWindowClosedNotification, selfPtr)
        AXObserverAddNotification(obs, axApp, kAXWindowCreatedNotification, selfPtr)
        AXObserverAddNotification(obs, axApp, kAXUIElementDestroyedNotification as CFString, selfPtr)

        // Add to main run loop
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        observers[pid] = obs
        print("Quitty: Successfully watching: \(app.localizedName ?? "App") (PID: \(pid))")
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
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        if notification == (kAXWindowCreatedNotification as String) {
            print("Quitty: Window created for \(app.localizedName ?? "app"). Cancelling pending quit.")
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
                print("Quitty: Warning - Failed to get windows for \(appName): \(err.rawValue)")
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
            
            let count = (windows as? [AXUIElement])?.filter { win in
                var sub: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &sub)
                let s = sub as? String ?? ""
                return s != kAXSheetSubrole && s != kAXDrawerSubrole
            }.count ?? 0
            
            if count == 0 {
                print("Quitty: Final check confirmed 0 windows for \(appName). Terminating.")
                DispatchQueue.main.async {
                    app.terminate()
                    self.pendingQuits.removeValue(forKey: pid)
                }
            } else {
                print("Quitty: Final check skipped termination for \(appName) (Window count: \(count))")
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
