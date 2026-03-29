
//
//  FeedbackEngine.swift
//  Quitty
//

import Cocoa
import Combine

// MARK: - Data Models

struct TerminationRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var bundleID: String
    var appName: String
    var appIconPath: String?          // Bundle path for icon lookup
    var windowSnapshots: [WindowSnapshot]
    var feedbackType: FeedbackType?   // nil = no feedback yet
}

struct WindowSnapshot: Codable {
    var width: CGFloat
    var height: CGFloat
    var layer: Int
    var isOnScreen: Bool
    var alpha: Double
    var name: String
}

enum FeedbackType: String, Codable {
    case falseQuit   = "false_quit"   // 误退: app quit but shouldn't have
    case cantQuit    = "cant_quit"    // 未退: app has no windows but refuses to quit (for future use)
}

// MARK: - Learned Rule

struct LearnedRule: Codable {
    var learnedGhostSizes: [LearnedSize]
    var ghostProneOverride: Bool
    var falseQuitCount: Int
    var cantQuitCount: Int
    var lastFeedbackType: FeedbackType?
}

struct LearnedSize: Codable, Equatable, Hashable {
    var width: CGFloat
    var height: CGFloat
    var tolerance: CGFloat
}

// MARK: - FeedbackEngine

class FeedbackEngine: ObservableObject {
    static let shared = FeedbackEngine()

    @Published var history: [TerminationRecord] = []

    /// Per-bundleID learned rules. Accessible via safe query methods.
    private var learnedRules: [String: LearnedRule] = [:]
    private let rulesQueue = DispatchQueue(label: "com.quitty.feedback.rules", attributes: .concurrent)

    private let maxHistory = 50
    private let historyURL: URL
    private let rulesURL: URL
    private let iCloudKey = "learned_rules_v1"

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Quitty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        historyURL = dir.appendingPathComponent("termination_history.json")
        rulesURL   = dir.appendingPathComponent("learned_rules.json")
        load()
        
        // Auto-save history
        $history
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveHistory() }
            .store(in: &cancellables)

        // Sync with iCloud
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudStoreDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidUpdate),
            name: Settings.didUpdateNotification,
            object: nil
        )
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    @objc private func settingsDidUpdate() {
        if Settings.shared.iCloudSyncEnabled {
            saveRules()
            loadFromICloud()
        }
    }

    @objc private func iCloudStoreDidChange(_ notification: Notification) {
        loadFromICloud()
    }

    // MARK: - Recording

    func recordTermination(pid: pid_t, bundleID: String, appName: String, bundlePath: String?) {
        autoreleasepool {
            let snapshots = captureSnapshots(pid: pid)
            let record = TerminationRecord(
                date: Date(),
                bundleID: bundleID,
                appName: appName,
                appIconPath: bundlePath,
                windowSnapshots: snapshots,
                feedbackType: nil
            )
            DispatchQueue.main.async {
                self.history.insert(record, at: 0)
                if self.history.count > self.maxHistory {
                    self.history = Array(self.history.prefix(self.maxHistory))
                }
                self.saveHistory()
            }
        }
    }

    private func captureSnapshots(pid: pid_t) -> [WindowSnapshot] {
        return autoreleasepool {
            let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionAll)
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                return []
            }
            return list.compactMap { w -> WindowSnapshot? in
                guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { return nil }
                guard let layer = w[kCGWindowLayer as String] as? Int, (0...100).contains(layer) else { return nil }
                let alpha  = w[kCGWindowAlpha as String] as? Double ?? 0
                let bounds = w[kCGWindowBounds as String] as? [String: Any]
                let width  = bounds?["Width"] as? CGFloat ?? 0
                let height = bounds?["Height"] as? CGFloat ?? 0
                let name   = (w[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
                return WindowSnapshot(width: width, height: height, layer: layer,
                                      isOnScreen: onScreen, alpha: alpha, name: name)
            }
        }
    }

    // MARK: - Feedback Actions

    func reportFalseQuit(recordID: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == recordID }) else { return }
        history[idx].feedbackType = .falseQuit
        let record = history[idx]
        learnFromFalseQuit(record: record)
        saveHistory()
        syncToCloud(record: record, type: .falseQuit)
        setLastFeedbackType(.falseQuit, for: record.bundleID)
        let logMsg = String(format: Settings.shared.localizedString("log_feedback_false_quit"), record.appName)
        Settings.shared.log(logMsg)
        objectWillChange.send()
    }

    func reportFalseQuit(bundleID: String, appName: String, bundlePath: String?) {
        let matchingRecord = history.first { 
            $0.bundleID == bundleID || $0.appName == appName || $0.appIconPath == bundlePath 
        }
        if let record = matchingRecord {
            reportFalseQuit(recordID: record.id)
        } else {
            rulesQueue.async(flags: .barrier) {
                var rule = self.learnedRules[bundleID] ?? LearnedRule(
                    learnedGhostSizes: [], ghostProneOverride: false,
                    falseQuitCount: 0, cantQuitCount: 0
                )
                rule.falseQuitCount += 1
                rule.ghostProneOverride = false // Should NOT be more aggressive if we already false-quit
                self.learnedRules[bundleID] = rule
                self.saveRulesInternal()
            }
            // Sync empty record for the counter tracking
            let tempRecord = TerminationRecord(date: Date(), bundleID: bundleID, appName: appName, appIconPath: bundlePath, windowSnapshots: [], feedbackType: .falseQuit)
            syncToCloud(record: tempRecord, type: .falseQuit)
            setLastFeedbackType(.falseQuit, for: bundleID)
            
            let logMsg = String(format: Settings.shared.localizedString("log_feedback_false_quit_no_history"), appName)
            Settings.shared.log(logMsg)
            objectWillChange.send()
        }
    }

    private func learnFromFalseQuit(record: TerminationRecord) {
        rulesQueue.async(flags: .barrier) {
            var rule = self.learnedRules[record.bundleID] ?? LearnedRule(
                learnedGhostSizes: [], ghostProneOverride: false,
                falseQuitCount: 0, cantQuitCount: 0
            )
            rule.falseQuitCount += 1
            rule.ghostProneOverride = false // Reset aggressive mode on false quit

            // If any existing ghost sizes match these real windows, remove them
            for snap in record.windowSnapshots {
                rule.learnedGhostSizes.removeAll { s in
                    abs(s.width - snap.width) < s.tolerance && abs(s.height - snap.height) < s.tolerance
                }
            }
            
            self.learnedRules[record.bundleID] = rule
            self.saveRulesInternal()
        }
    }

    func reportCantQuit(bundleID: String, appName: String, pid: pid_t?) {
        let snapshots = pid.map { captureSnapshots(pid: $0) } ?? []
        rulesQueue.async(flags: .barrier) {
            var rule = self.learnedRules[bundleID] ?? LearnedRule(
                learnedGhostSizes: [], ghostProneOverride: false,
                falseQuitCount: 0, cantQuitCount: 0
            )
            rule.cantQuitCount += 1
            for snap in snapshots where snap.name.isEmpty && snap.width > 30 && snap.height > 30 {
                let newSize = LearnedSize(width: snap.width, height: snap.height, tolerance: 20)
                if !rule.learnedGhostSizes.contains(where: { 
                    abs($0.width - newSize.width) < $0.tolerance && abs($0.height - newSize.height) < $0.tolerance
                }) {
                    rule.learnedGhostSizes.append(newSize)
                    let logMsg = String(format: Settings.shared.localizedString("log_learned_ghost"), Int(newSize.width), Int(newSize.height))
                    Settings.shared.log(logMsg)
                }
            }
            // If we have more failures to quit than false quits, become more aggressive
            if rule.cantQuitCount > rule.falseQuitCount {
                rule.ghostProneOverride = true
            }
            self.learnedRules[bundleID] = rule
            self.saveRulesInternal()
        }
        
        let record = TerminationRecord(
            date: Date(),
            bundleID: bundleID,
            appName: appName,
            appIconPath: nil,
            windowSnapshots: snapshots,
            feedbackType: .cantQuit
        )
        syncToCloud(record: record, type: .cantQuit)
        setLastFeedbackType(.cantQuit, for: bundleID)

        let logMsg = String(format: Settings.shared.localizedString("log_feedback_cant_quit"), appName, snapshots.count)
        Settings.shared.log(logMsg)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func undoFeedback(for bundleID: String) {
        rulesQueue.async(flags: .barrier) {
            guard var rule = self.learnedRules[bundleID], let type = rule.lastFeedbackType else { return }
            
            if type == .falseQuit {
                rule.falseQuitCount = max(0, rule.falseQuitCount - 1)
            } else if type == .cantQuit {
                rule.cantQuitCount = max(0, rule.cantQuitCount - 1)
                // Cannot easily undo learned sizes without more complex tracking,
                // but we can at least revert the counters and type.
            }
            
            rule.lastFeedbackType = nil
            
            // Re-evaluate ghostProneOverride
            if rule.cantQuitCount <= rule.falseQuitCount {
                rule.ghostProneOverride = false
            }
            
            self.learnedRules[bundleID] = rule
            self.saveRulesInternal()
            
            Settings.shared.log("Feedback [\(type.rawValue)] undone for \(bundleID).")
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    func undoFeedback(recordID: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == recordID }) else { return }
        let type = history[idx].feedbackType
        let bundleID = history[idx].bundleID
        
        history[idx].feedbackType = nil
        saveHistory()
        
        if let ft = type {
            rulesQueue.async(flags: .barrier) {
                guard var rule = self.learnedRules[bundleID] else { return }
                if ft == .falseQuit {
                    rule.falseQuitCount = max(0, rule.falseQuitCount - 1)
                } else if ft == .cantQuit {
                    rule.cantQuitCount = max(0, rule.cantQuitCount - 1)
                }
                
                if rule.lastFeedbackType == ft {
                    rule.lastFeedbackType = nil
                }
                
                if rule.cantQuitCount <= rule.falseQuitCount {
                    rule.ghostProneOverride = false
                }
                
                self.learnedRules[bundleID] = rule
                self.saveRulesInternal()
            }
        }
        
        Settings.shared.log("Feedback record \(recordID) undone.")
        objectWillChange.send()
    }

    private func setLastFeedbackType(_ type: FeedbackType, for bundleID: String) {
        rulesQueue.async(flags: .barrier) {
            var rule = self.learnedRules[bundleID] ?? LearnedRule(
                learnedGhostSizes: [], ghostProneOverride: false,
                falseQuitCount: 0, cantQuitCount: 0, lastFeedbackType: nil
            )
            rule.lastFeedbackType = type
            self.learnedRules[bundleID] = rule
            self.saveRulesInternal()
        }
    }

    // MARK: - Query Logic (Thread-safe)

    func isLearnedGhostSize(bundleID: String, width: CGFloat, height: CGFloat) -> Bool {
        var found = false
        rulesQueue.sync {
            guard let rule = learnedRules[bundleID] else { return }
            found = rule.learnedGhostSizes.contains { s in
                abs(s.width - width) < s.tolerance && abs(s.height - height) < s.tolerance
            }
        }
        return found
    }

    func isGhostProneOverride(bundleID: String) -> Bool {
        return rulesQueue.sync { learnedRules[bundleID]?.ghostProneOverride ?? false }
    }

    func lastFeedbackType(for bundleID: String) -> FeedbackType? {
        return rulesQueue.sync { learnedRules[bundleID]?.lastFeedbackType }
    }

    func sensitivityMultiplier(bundleID: String) -> CGFloat {
        rulesQueue.sync {
            guard let rule = learnedRules[bundleID] else { return 1.0 }
            let net = rule.cantQuitCount - rule.falseQuitCount
            if net == 0 { return 1.0 }
            if net > 0 {
                // Cant-quit prone (net positive) -> return > 1.0 -> ignore MORE stuff
                return 1.0 + CGFloat(min(net, 10)) * 0.4
            } else {
                // False-quit prone (net negative) -> return < 1.0 -> ignore LESS stuff
                // We drop faster to 0.1 for maximum caution
                return max(0.1, 1.0 + CGFloat(max(net, -10)) * 0.2)
            }
        }
    }

    // MARK: - Helpers

    func appIcon(for record: TerminationRecord) -> NSImage {
        if let path = record.appIconPath { return NSWorkspace.shared.icon(forFile: path) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFileType: "app")
    }

    // MARK: - Persistence & Sync

    private func load() {
        if let data = try? Data(contentsOf: historyURL),
           let decoded = try? JSONDecoder().decode([TerminationRecord].self, from: data) {
            history = decoded
        }
        if let data = try? Data(contentsOf: rulesURL),
           let decoded = try? JSONDecoder().decode([String: LearnedRule].self, from: data) {
            rulesQueue.async(flags: .barrier) { self.learnedRules = decoded }
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL)
        }
    }

    func saveRules() {
        rulesQueue.async(flags: .barrier) { self.saveRulesInternal() }
    }

    private func saveRulesInternal() {
        if let data = try? JSONEncoder().encode(learnedRules) {
            try? data.write(to: rulesURL)
            if Settings.shared.iCloudSyncEnabled {
                NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
                NSUbiquitousKeyValueStore.default.synchronize()
            }
        }
    }

    private func loadFromICloud() {
        guard Settings.shared.iCloudSyncEnabled else { return }
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey) else { return }
        do {
            let incoming = try JSONDecoder().decode([String: LearnedRule].self, from: data)
            mergeRules(incoming)
            Settings.shared.log("Merged rules from iCloud.")
            DispatchQueue.main.async { self.objectWillChange.send() }
        } catch { print("iCloud Rules Decode Error: \(error)") }
    }

    private func mergeRules(_ incoming: [String: LearnedRule]) {
        rulesQueue.async(flags: .barrier) {
            for (bundleID, newRule) in incoming {
                if var existing = self.learnedRules[bundleID] {
                    existing.falseQuitCount = max(existing.falseQuitCount, newRule.falseQuitCount)
                    existing.cantQuitCount = max(existing.cantQuitCount, newRule.cantQuitCount)
                    existing.ghostProneOverride = existing.ghostProneOverride || newRule.ghostProneOverride
                    let union = Set(existing.learnedGhostSizes).union(Set(newRule.learnedGhostSizes))
                    existing.learnedGhostSizes = Array(union)
                    self.learnedRules[bundleID] = existing
                } else {
                    self.learnedRules[bundleID] = newRule
                }
            }
            if let data = try? JSONEncoder().encode(self.learnedRules) {
                try? data.write(to: self.rulesURL)
            }
        }
    }

    // MARK: - Cloud Reporting

    private func syncToCloud(record: TerminationRecord, type: FeedbackType) {
        let apiURL = URL(string: "https://api.ct106.cc/quitty")!
        
        // 1. Report Main Record (feedback_records)
        let mainParams: [String: String] = [
            "table": "feedback_records",
            "id": record.id.uuidString,
            "bundle_id": record.bundleID,
            "app_name": record.appName,
            "app_icon_path": record.appIconPath ?? "",
            "feedback_type": type.rawValue,
            "created_at": ISO8601DateFormatter().string(from: record.date)
        ]
        sendPostRequest(url: apiURL, params: mainParams)
        
        // 2. Report Snapshots (window_snapshots)
        for snap in record.windowSnapshots {
            let snapParams: [String: String] = [
                "table": "window_snapshots",
                "record_id": record.id.uuidString,
                "width": String(format: "%.2f", snap.width),
                "height": String(format: "%.2f", snap.height),
                "layer": String(snap.layer),
                "is_on_screen": snap.isOnScreen ? "1" : "0",
                "alpha": String(format: "%.3f", snap.alpha),
                "window_name": snap.name
            ]
            sendPostRequest(url: apiURL, params: snapParams)
        }
    }

    private func sendPostRequest(url: URL, params: [String: String]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyString = params.map { 
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" 
        }.joined(separator: "&")
        
        request.httpBody = bodyString.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Settings.shared.log("Cloud sync error: \(error.localizedDescription)")
            }
        }.resume()
    }
}
