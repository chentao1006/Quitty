
//
//  Settings.swift
//  Quitty
//

import SwiftUI
import ServiceManagement
import Cocoa

class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    static let didUpdateNotification = Notification.Name("QuittySettingsDidUpdate")
    
    // Captured logs for UI display
    @Published var logs: [String] = []
    private let maxLogLines = 100

    func log(_ message: String) {
        print("Quitty: \(message)")
        DispatchQueue.main.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] \(message)"
            self.logs.append(line)
            if self.logs.count > self.maxLogLines {
                self.logs.removeFirst()
            }
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
