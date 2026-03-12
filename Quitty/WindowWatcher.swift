
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

    // One AXObserver per running app PID
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingQuits: [pid_t: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.quitty.watcher", qos: .userInitiated)

    // MARK: - Public Interface

    func start() {
        setupWorkspaceObservers()
        // Watch all currently running apps – move to background to avoid freezing UI
        queue.async {
            for app in NSWorkspace.shared.runningApplications {
                self.watchApp(app)
            }
        }
    }

    func stop() {
        // Remove all AX observers
        for (pid, observer) in observers {
            if let app = NSRunningApplication(processIdentifier: pid) {
                removeObserver(observer, for: app)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observers.removeAll()
        pendingQuits.removeAll()

        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
        
        // Remove from observers and cleanup
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            print("Successfully removed observer for terminated PID: \(pid)")
        }
        
        pendingQuits[pid]?.cancel()
        pendingQuits.removeValue(forKey: pid)
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

        print("Attempting to watch: \(app.localizedName ?? "Unknown") (PID: \(pid))")

        // Create AX element for the target app
        let axApp = AXUIElementCreateApplication(pid)

        // Create an AXObserver with callback
        var observer: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let err = AXObserverCreate(pid, { (observer, element, notification, userData) in
            guard let userData = userData else { return }
            let watcher = Unmanaged<WindowWatcher>.fromOpaque(userData).takeUnretainedValue()
            let elementPid = AXUIElementGetPid(element)
            let notificationName = notification as String
            print("Received accessibility notification: \(notificationName) for PID: \(elementPid)")
            watcher.handleAXNotification(element: element, notification: notificationName, pid: elementPid)
        }, &observer)

        guard err == .success, let obs = observer else {
            print("Failed to create AXObserver for PID \(pid): \(err.rawValue)")
            return
        }

        // Subscribe to window closed events
        _ = AXObserverAddNotification(obs, axApp, kAXWindowClosedNotification, selfPtr)
        
        // Also subscribe to window creation to cancel any pending quits
        _ = AXObserverAddNotification(obs, axApp, kAXWindowCreatedNotification, selfPtr)
        
        // Also subscribe to UI element destroyed (catches some Sequoia cases where window closed isn't enough)
        _ = AXObserverAddNotification(obs, axApp, kAXUIElementDestroyedNotification as CFString, selfPtr)
        
        // Always proceed if we reach here, raw AX API might report error even if it works on Sequoia
        // We'll trust that some notifications were registered.

        // Add to main run loop
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        observers[pid] = obs
        print("Now watching: \(app.localizedName ?? "App") (PID: \(pid))")
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
            // New window appeared! Cancel any pending quit immediately
            print("Window created for \(app.localizedName ?? "app"). Cancelling pending quit.")
            DispatchQueue.main.async {
                self.pendingQuits[pid]?.cancel()
                self.pendingQuits.removeValue(forKey: pid)
            }
            return
        }

        // For closed/destroyed events, check if we should quit
        // Small delay to let the window list update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.checkAndQuit(app: app)
        }
    }

    // MARK: - Quit Logic

    private func checkAndQuit(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        
        // Skip if already terminated or if we have a pending quit that's about to fire
        guard !app.isTerminated else { return }

        // Use a background queue for AX calls to avoid blocking the main thread if the target app hangs
        queue.async { [weak self] in
            guard let self = self else { return }
            
            print("Checking if \(appName) should quit...")

            // Get window list using Accessibility API
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

            var windowCount = 0
            if err == .success, let windows = windowsRef as? [AXUIElement] {
                // Filter out minimized or sheet windows – only count "real" visible windows
                windowCount = windows.filter { window in
                    var subrole: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                    let sub = subrole as? String ?? ""

                    // Count all windows except sheets and drawers. 
                    // Minimized windows NOW COUNT as active windows to prevent accidental kills.
                    let keep = sub != kAXSheetSubrole && sub != kAXDrawerSubrole
                    return keep
                }.count
                print("Active window count for \(appName): \(windowCount)")
            } else {
                print("Failed to get windows for \(appName): \(err.rawValue)")
                // If we can't get windows, assume we shouldn't quit yet to be safe
                return
            }

            if windowCount > 0 {
                // App still has visible windows – cancel any pending quit
                DispatchQueue.main.async {
                    self.pendingQuits[pid]?.cancel()
                    self.pendingQuits.removeValue(forKey: pid)
                }
                return
            }

            // Check settings – should we quit this app?
            guard let bundlePath = app.bundleURL?.path else { return }
            let bundleID = app.bundleIdentifier
            if !Settings.shared.shouldQuitApp(bundlePath: bundlePath, bundleID: bundleID) {
                return
            }

            // Back to main thread to schedule the delayed quit
            DispatchQueue.main.async {
                // Cancel any previous pending quit for this pid
                self.pendingQuits[pid]?.cancel()
                
                let delay = Settings.shared.closeDelay
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.pendingQuits.removeValue(forKey: pid)
                    
                    // Double-check app is still there and still has no windows
                    guard let runningApp = NSRunningApplication(processIdentifier: pid),
                          !runningApp.isTerminated else { return }

                    // Re-run window check one last time on background queue before final termination
                    self.queue.async {
                        let axCheck = AXUIElementCreateApplication(pid)
                        var wins: CFTypeRef?
                        let res = AXUIElementCopyAttributeValue(axCheck, kAXWindowsAttribute as CFString, &wins)
                        
                        guard res == .success, let windows = wins as? [AXUIElement] else {
                            print("Quitty: Final check failed for \(appName), skipping quit to be safe.")
                            return
                        }

                        let count = windows.filter { window in
                            var subrole: CFTypeRef?
                            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                            let sub = subrole as? String ?? ""
                            return sub != kAXSheetSubrole && sub != kAXDrawerSubrole
                        }.count
                        
                        if count == 0 {
                            print("Quitty: Terminating \(runningApp.localizedName ?? "<unknown>") (PID: \(pid))")
                            DispatchQueue.main.async {
                                runningApp.terminate()
                            }
                        }
                    }
                }

                self.pendingQuits[pid] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
