
//
//  Settings.swift
//  Quitty
//

import SwiftUI
import ServiceManagement
import Cocoa

struct WatcherDiagnosticRow: Identifiable {
    let id: String
    let appName: String
    let bundleIdentifier: String?
    let bundlePath: String?
    let totalTrackedMs: Int
    let loadHistory: [Double]
    let axChecks: Int
    let axAverageMs: Int
    let cgChecks: Int
    let cgAverageMs: Int
    let rescueScans: Int
    let notifications: Int
    let duplicateSkips: Int
}

enum LogTone {
    case neutral
    case success
    case warning
    case failure
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let message: String
    let tone: LogTone

    var line: String {
        "[\(timestamp)] \(message)"
    }
}

class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let didUpdateNotification = Notification.Name("QuittySettingsDidUpdate")
    
    // Captured logs for UI display
    @Published var logs: [LogEntry] = []
    @Published var watcherDiagnostics: [WatcherDiagnosticRow] = []
    @Published var watcherDiagnosticsUpdatedAt: Date?
    var isWatcherDiagnosticsVisible = false
    private let maxLogLines = 100

    func log(_ message: String) {
        print("Quitty: \(message)")
        DispatchQueue.main.async {
            let timestamp = Self.logDateFormatter.string(from: Date())
            let entry = LogEntry(timestamp: timestamp, message: message, tone: Self.inferLogTone(for: message))
            self.logs.append(entry)
            if self.logs.count > self.maxLogLines {
                self.logs.removeFirst()
            }
        }
    }

    var exportedLogsText: String {
        logs.map(\.line).joined(separator: "\n")
    }

    private static func inferLogTone(for message: String) -> LogTone {
        let lowercased = message.lowercased()

        if lowercased.contains("terminating") || lowercased.contains("confirmed 0 windows") || lowercased.contains("completed successfully") {
            return .success
        }

        if lowercased.contains("aborting") || lowercased.contains("aborted") || lowercased.contains("skipped") || lowercased.contains("cancel") || lowercased.contains("postponing") || lowercased.contains("deferring") {
            return .warning
        }

        if lowercased.contains("error") || lowercased.contains("failed") || lowercased.contains("warning - failed") || lowercased.contains("critical") {
            return .failure
        }

        return .neutral
    }

    func updateWatcherDiagnostics(_ diagnostics: [WatcherDiagnosticRow]) {
        DispatchQueue.main.async {
            self.watcherDiagnostics = diagnostics
            self.watcherDiagnosticsUpdatedAt = diagnostics.isEmpty ? nil : Date()
        }
    }

    func clearWatcherDiagnostics() {
        DispatchQueue.main.async {
            self.watcherDiagnostics.removeAll()
            self.watcherDiagnosticsUpdatedAt = nil
        }
    }

    // MARK: - Keys
    private enum Key: String {
        case launchHidden       = "launchHidden"
        case menubarIconEnabled = "menubarIconEnabled"
        case excludeBehaviour   = "excludeBehaviour"
        case excludedApps       = "excludedApps"
        case launchAtLogin      = "launchAtLogin"
        case appLanguage        = "appLanguage"
        case iCloudSyncEnabled  = "iCloudSyncEnabled"
    }

    init() {
        setupICloudSync()
    }

    // MARK: - Localization

    func localizedString(_ key: String) -> String {
        let language = appLanguage
        if language == "system" {
            return NSLocalizedString(key, comment: "")
        }
        
        let code = language == "zh" ? "zh-Hans" : "en"
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return NSLocalizedString(key, tableName: nil, bundle: bundle, value: "", comment: "")
        }
        
        return NSLocalizedString(key, comment: "")
    }

    // MARK: - iCloud Sync Logic

    private func setupICloudSync() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudStoreDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        NSUbiquitousKeyValueStore.default.synchronize()
        
        if iCloudSyncEnabled {
            loadFromICloud()
        }
    }

    @objc private func iCloudStoreDidChange(_ notification: Notification) {
        guard iCloudSyncEnabled else { return }
        
        DispatchQueue.main.async {
            self.loadFromICloud()
            self.log("iCloud data changed externally, settings updated")
        }
    }

    func saveToICloud() {
        guard iCloudSyncEnabled else { return }
        let store = NSUbiquitousKeyValueStore.default
        
        store.set(launchHidden, forKey: Key.launchHidden.rawValue)
        store.set(menubarIconEnabled, forKey: Key.menubarIconEnabled.rawValue)
        store.set(excludeBehaviour, forKey: Key.excludeBehaviour.rawValue)
        store.set(excludedApps, forKey: Key.excludedApps.rawValue)
        store.set(appLanguage, forKey: Key.appLanguage.rawValue)
        
        store.synchronize()
        log("Settings saved to iCloud")
    }

    func loadFromICloud() {
        guard iCloudSyncEnabled else { return }
        let store = NSUbiquitousKeyValueStore.default
        
        var changed = false
        
        if let v = store.object(forKey: Key.launchHidden.rawValue) as? Bool {
            if v != launchHidden {
                defaults.set(v, forKey: Key.launchHidden.rawValue)
                changed = true
            }
        }
        if let v = store.object(forKey: Key.menubarIconEnabled.rawValue) as? Bool {
            if v != menubarIconEnabled {
                defaults.set(v, forKey: Key.menubarIconEnabled.rawValue)
                changed = true
            }
        }
        if let v = store.string(forKey: Key.excludeBehaviour.rawValue) {
            if v != excludeBehaviour {
                defaults.set(v, forKey: Key.excludeBehaviour.rawValue)
                changed = true
            }
        }
        if let v = store.array(forKey: Key.excludedApps.rawValue) as? [String] {
            if v != excludedApps {
                defaults.set(v, forKey: Key.excludedApps.rawValue)
                changed = true
            }
        }
        if let v = store.string(forKey: Key.appLanguage.rawValue) {
            if v != appLanguage {
                defaults.set(v, forKey: Key.appLanguage.rawValue)
                changed = true
            }
        }
        
        if changed {
            objectWillChange.send()
            NotificationCenter.default.post(name: Settings.didUpdateNotification, object: nil)
        }
    }

    // MARK: - Import/Export

    func exportToJSON() -> Data? {
        let data: [String: Any] = [
            Key.launchHidden.rawValue: launchHidden,
            Key.menubarIconEnabled.rawValue: menubarIconEnabled,
            Key.excludeBehaviour.rawValue: excludeBehaviour,
            Key.excludedApps.rawValue: excludedApps,
            Key.appLanguage.rawValue: appLanguage
        ]
        return try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
    }

    func importFromJSON(data: Data) -> Bool {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                objectWillChange.send()
                
                if let v = json[Key.launchHidden.rawValue] as? Bool { 
                    defaults.set(v, forKey: Key.launchHidden.rawValue) 
                }
                if let v = json[Key.menubarIconEnabled.rawValue] as? Bool { 
                    defaults.set(v, forKey: Key.menubarIconEnabled.rawValue) 
                }
                if let v = json[Key.excludeBehaviour.rawValue] as? String { 
                    defaults.set(v, forKey: Key.excludeBehaviour.rawValue) 
                }
                if let v = json[Key.excludedApps.rawValue] as? [String] { 
                    defaults.set(v, forKey: Key.excludedApps.rawValue) 
                }
                if let v = json[Key.appLanguage.rawValue] as? String { 
                    defaults.set(v, forKey: Key.appLanguage.rawValue) 
                }
                
                saveToICloud()
                NotificationCenter.default.post(name: Settings.didUpdateNotification, object: nil)
                return true
            }
        } catch {
            log("Error importing settings: \(error)")
        }
        return false
    }

    // MARK: - Properties

    var launchHidden: Bool {
        get { defaults.object(forKey: Key.launchHidden.rawValue) as? Bool ?? false }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.launchHidden.rawValue)
            saveToICloud()
        }
    }

    var menubarIconEnabled: Bool {
        get { defaults.object(forKey: Key.menubarIconEnabled.rawValue) as? Bool ?? true }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.menubarIconEnabled.rawValue)
            saveToICloud()
        }
    }

    var excludeBehaviour: String {
        get { defaults.string(forKey: Key.excludeBehaviour.rawValue) ?? "includeApps" }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.excludeBehaviour.rawValue)
            saveToICloud()
        }
    }

    var excludedApps: [String] {
        get { defaults.stringArray(forKey: Key.excludedApps.rawValue) ?? [] }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.excludedApps.rawValue)
            saveToICloud()
        }
    }

    var appLanguage: String {
        get { defaults.string(forKey: Key.appLanguage.rawValue) ?? "system" }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.appLanguage.rawValue)
            saveToICloud()
        }
    }

    var iCloudSyncEnabled: Bool {
        get { defaults.bool(forKey: Key.iCloudSyncEnabled.rawValue) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.iCloudSyncEnabled.rawValue)
            if newValue {
                saveToICloud()
                NSUbiquitousKeyValueStore.default.synchronize()
            }
        }
    }


    var launchAtLogin: Bool {
        get { defaults.object(forKey: Key.launchAtLogin.rawValue) as? Bool ?? false }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.launchAtLogin.rawValue)
            updateLaunchAtLogin(enabled: newValue)
        }
    }

    var isAccessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Launch At Login

    private func updateLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("LaunchAtLogin error: \(error)")
            }
        }
    }

    // MARK: - App Filter Logic

    /// Returns true if the app at the given bundle path should be auto-quit
    func shouldQuitApp(bundlePath: String, bundleID: String?) -> Bool {
        if isSystemApp(bundlePath: bundlePath, bundleID: bundleID) { return false }

        let isInList = excludedApps.contains(bundlePath) || excludedApps.contains(bundleID ?? "")

        if excludeBehaviour == "excludeApps" {
            // Quit everything EXCEPT apps in the list
            return !isInList
        } else {
            // Quit ONLY apps in the list
            return isInList
        }
    }

    /// Returns true if we should even bother watching this app's windows
    func isPotentiallyRelevant(bundlePath: String?, bundleID: String?) -> Bool {
        guard let path = bundlePath else { return false }
        if isSystemApp(bundlePath: path, bundleID: bundleID) { return false }

        let isInList = excludedApps.contains(path) || excludedApps.contains(bundleID ?? "")

        if excludeBehaviour == "excludeApps" {
            // In "Exclude from Quitting" mode, we watch everyone NOT in the list
            return !isInList
        } else {
            // In "Only Quit These" mode, we ONLY watch apps in the list
            return isInList
        }
    }

    private func isSystemApp(bundlePath: String, bundleID: String?) -> Bool {
        // Never quit system services
        let systemPaths = [
            "/System/Library/CoreServices/Finder.app",
            "/System/Library/CoreServices/Spotlight.app",
            "/System/Library/CoreServices/NotificationCenter.app",
            "/System/Library/CoreServices/SystemUIServer.app",
            "/System/Library/CoreServices/Dock.app",
            "/System/Library/CoreServices/ControlCenter.app",
            "/System/Library/CoreServices/WindowManager.app",
            "/System/Library/CoreServices/TextInputMenuAgent.app",
            "/System/Library/CoreServices/System Events.app",
            "/usr/libexec/backboardd"
        ]
        if systemPaths.contains(bundlePath) { return true }

        // Never quit ourselves
        let myBundleID = Bundle.main.bundleIdentifier ?? ""
        if let bid = bundleID, bid == myBundleID { return true }
        
        return false
    }
}
