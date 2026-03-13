
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
    private var fileWatcher: DispatchSourceFileSystemObject?

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
        case closeDelay         = "closeDelay"
        case launchAtLogin      = "launchAtLogin"
        case appLanguage        = "appLanguage"
        case fileSyncEnabled    = "fileSyncEnabled"
        case syncFilePath       = "syncFilePath"
    }

    init() {
        if fileSyncEnabled {
            startWatchingFile()
            loadFromFile() // Initial load
        }
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

    // MARK: - File Sync Logic

    private var defaultSyncFolderPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloudPath = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Quitty")
        
        // Try to create the folder in iCloud Drive, or fallback to Documents
        do {
            try FileManager.default.createDirectory(at: iCloudPath, withIntermediateDirectories: true)
            return iCloudPath.path
        } catch {
            let docs = home.appendingPathComponent("Documents/Quitty")
            _ = try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs.path
        }
    }

    private var settingsFileURL: URL {
        return URL(fileURLWithPath: syncFilePath).appendingPathComponent("settings.json")
    }

    func saveToFile() {
        guard fileSyncEnabled else { return }
        let fileURL = settingsFileURL
        let data: [String: Any] = [
            Key.launchHidden.rawValue: launchHidden,
            Key.menubarIconEnabled.rawValue: menubarIconEnabled,
            Key.excludeBehaviour.rawValue: excludeBehaviour,
            Key.excludedApps.rawValue: excludedApps,
            Key.closeDelay.rawValue: closeDelay,
            Key.appLanguage.rawValue: appLanguage
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
            try jsonData.write(to: fileURL)
            print("Settings saved to file: \(fileURL.path)")
        } catch {
            print("Error saving to file: \(error)")
        }
    }

    func loadFromFile() {
        guard fileSyncEnabled else { return }
        let fileURL = settingsFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Update local defaults without triggering save loop
                if let v = json[Key.launchHidden.rawValue] as? Bool { defaults.set(v, forKey: Key.launchHidden.rawValue) }
                if let v = json[Key.menubarIconEnabled.rawValue] as? Bool { defaults.set(v, forKey: Key.menubarIconEnabled.rawValue) }
                if let v = json[Key.excludeBehaviour.rawValue] as? String { defaults.set(v, forKey: Key.excludeBehaviour.rawValue) }
                if let v = json[Key.excludedApps.rawValue] as? [String] { defaults.set(v, forKey: Key.excludedApps.rawValue) }
                if let v = json[Key.closeDelay.rawValue] as? Double { defaults.set(v, forKey: Key.closeDelay.rawValue) }
                if let v = json[Key.appLanguage.rawValue] as? String { defaults.set(v, forKey: Key.appLanguage.rawValue) }
                
                print("Settings loaded from file: \(fileURL.path)")
                NotificationCenter.default.post(name: Settings.didUpdateNotification, object: nil)
            }
        } catch {
            print("Error loading from file: \(error)")
        }
    }

    private func startWatchingFile() {
        fileWatcher?.cancel()
        
        let fileURL = settingsFileURL
        let path = fileURL.path
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }
        
        fileWatcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: .main)
        fileWatcher?.setEventHandler { [weak self] in
            print("External file change detected")
            self?.loadFromFile()
        }
        fileWatcher?.setCancelHandler {
            close(fileDescriptor)
        }
        fileWatcher?.resume()
    }

    // MARK: - Properties

    var fileSyncEnabled: Bool {
        get { defaults.bool(forKey: Key.fileSyncEnabled.rawValue) }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.fileSyncEnabled.rawValue)
            if newValue {
                saveToFile() // Initial push
                startWatchingFile()
            } else {
                fileWatcher?.cancel()
            }
        }
    }

    var syncFilePath: String {
        get { defaults.string(forKey: Key.syncFilePath.rawValue) ?? defaultSyncFolderPath }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.syncFilePath.rawValue)
            if fileSyncEnabled {
                startWatchingFile()
                saveToFile()
            }
        }
    }

    var appLanguage: String {
        get { defaults.string(forKey: Key.appLanguage.rawValue) ?? "system" }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.appLanguage.rawValue)
            saveToFile()
        }
    }

    var launchHidden: Bool {
        get { defaults.object(forKey: Key.launchHidden.rawValue) as? Bool ?? false }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.launchHidden.rawValue)
            saveToFile()
        }
    }

    var menubarIconEnabled: Bool {
        get { defaults.object(forKey: Key.menubarIconEnabled.rawValue) as? Bool ?? true }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.menubarIconEnabled.rawValue)
            saveToFile()
        }
    }

    var excludeBehaviour: String {
        get { defaults.string(forKey: Key.excludeBehaviour.rawValue) ?? "includeApps" }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.excludeBehaviour.rawValue)
            saveToFile()
        }
    }

    var excludedApps: [String] {
        get { defaults.stringArray(forKey: Key.excludedApps.rawValue) ?? [] }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.excludedApps.rawValue)
            saveToFile()
        }
    }

    var closeDelay: Double {
        get { defaults.object(forKey: Key.closeDelay.rawValue) as? Double ?? 2.0 }
        set { 
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.closeDelay.rawValue)
            saveToFile()
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
