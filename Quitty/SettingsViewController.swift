import SwiftUI
import Cocoa
import UniformTypeIdentifiers

class SettingsViewController: NSHostingController<SettingsView> {
    init() {
        let settings = Settings.shared
        super.init(rootView: SettingsView(settings: settings))
    }
    
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var selectedTab: Int = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_general"), systemImage: "gearshape")
                }
                .tag(0)
            
            AppListSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_apps"), systemImage: "list.bullet")
                }
                .tag(1)
            
            HistorySettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_history"), systemImage: "clock.arrow.circlepath")
                }
                .tag(2)
            
            DataSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_data"), systemImage: "externaldrive")
                }
                .tag(3)
            
            AboutSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_about"), systemImage: "info.circle")
                }
                .tag(4)
        }
        // Force redraw on language change AND force a wide layout to prevent collapse
        .id(settings.appLanguage)
        .frame(minWidth: 650, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .onAppear {
            syncWatcherDiagnosticsVisibility()
        }
        .onChange(of: selectedTab) { _ in
            syncWatcherDiagnosticsVisibility()
        }
        .onDisappear {
            settings.isWatcherDiagnosticsVisible = false
            settings.clearWatcherDiagnostics()
        }
    }

    private func syncWatcherDiagnosticsVisibility() {
        let isVisible = selectedTab == 3
        settings.isWatcherDiagnosticsVisible = isVisible

        if isVisible {
            (NSApplication.shared.delegate as? AppDelegate)?.windowWatcher.refreshDiagnosticsDisplay()
        } else {
            settings.clearWatcherDiagnostics()
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: Settings
    
    var body: some View {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            generalFormBody
            .formStyle(.grouped)
        } else {
            generalFormBody
        }
        #endif
    }

    private var generalFormBody: some View {
        Form {
            Section {
                Toggle(settings.localizedString("launch_at_login"), isOn: $settings.launchAtLogin)
                Toggle(settings.localizedString("launch_hidden"), isOn: $settings.launchHidden)
                Toggle(settings.localizedString("show_menubar_icon"), isOn: $settings.menubarIconEnabled)

                Picker(settings.localizedString("language"), selection: $settings.appLanguage) {
                    Text(settings.localizedString("lang_system")).tag("system")
                    Text(settings.localizedString("lang_en")).tag("en")
                    Text(settings.localizedString("lang_zh")).tag("zh")
                }
            } header: {
                Text(settings.localizedString("section_general"))
            }

            Section {
                HStack {
                    Text(settings.localizedString("accessibility_access"))
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(settings.isAccessibilityAuthorized ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(settings.localizedString(settings.isAccessibilityAuthorized ? "status_authorized" : "status_unauthorized"))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button(settings.localizedString(settings.isAccessibilityAuthorized ? "btn_check" : "btn_grant")) {
                        if let delegate = NSApplication.shared.delegate as? AppDelegate {
                            delegate.checkAccessibilityPermissions(silent: false)
                            settings.objectWillChange.send()
                        }
                    }

                    if !settings.isAccessibilityAuthorized {
                        Text(settings.localizedString("permission_desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(settings.localizedString("section_permissions"))
            }

            SyncBackupSectionView(settings: settings)
        }
    }
}

struct AboutSettingsView: View {
    @ObservedObject var settings: Settings
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            
            VStack(spacing: 8) {
                Text(settings.localizedString("app_name"))
                    .font(.title).bold()
                
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Text(settings.localizedString("subtitle"))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            Spacer()
            
            VStack(spacing: 12) {
                Button(settings.localizedString("menu_check_updates")) {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.updaterController.checkForUpdates(nil)
                    }
                }
                .buttonStyle(.bordered)
                
                Link(destination: URL(string: "https://github.com/chentao1006/Quitty")!) {
                    Text(settings.localizedString("github"))
                        .font(.body)
                        .foregroundColor(.accentColor)
                }
            }
            
            Text("© 2026 chentao1006")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}



struct AppListSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var feedback: FeedbackEngine = .shared
    @State private var selection: String?
    @State private var searchText: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.localizedString("section_apps"))
                .font(.headline)
            
            Picker(settings.localizedString("mode"), selection: $settings.excludeBehaviour) {
                Text(settings.localizedString("mode_include")).tag("includeApps")
                Text(settings.localizedString("mode_exclude")).tag("excludeApps")
            }
            .pickerStyle(.radioGroup)
            
            Text(settings.excludeBehaviour == "excludeApps" ? settings.localizedString("desc_exclude") : settings.localizedString("desc_include"))
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(settings.localizedString("search_apps_placeholder"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(filteredAppIdentifiers, id: \.self) { identifier in
                            HStack {
                                AppListRow(identifier: identifier)
                                Spacer()
                                let info = resolveAppInfo(for: identifier)
                                if let ft = feedback.lastFeedbackType(for: info.bundleID ?? identifier) {
                                    HStack(spacing: 4) {
                                        Image(systemName: ft == .falseQuit ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                            .foregroundColor(ft == .falseQuit ? .orange : .green)
                                            .font(.caption2)
                                        Text(settings.localizedString(ft == .falseQuit ? "feedback_false_quit" : "feedback_cant_quit"))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        
                                        Button {
                                            let bID = info.bundleID ?? identifier
                                            feedback.undoFeedback(for: bID)
                                        } label: {
                                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                                .font(.caption2)
                                                .foregroundColor(.secondary.opacity(0.8))
                                        }
                                        .buttonStyle(.plain)
                                        .help(settings.localizedString("btn_undo_feedback"))
                                    }
                                    .padding(.horizontal, 4)
                                }

                                Menu {
                                    Button(settings.localizedString("btn_false_quit")) {
                                        let info = resolveAppInfo(for: identifier)
                                        FeedbackEngine.shared.reportFalseQuit(
                                            bundleID: info.bundleID ?? identifier,
                                            appName: info.name,
                                            bundlePath: identifier.hasPrefix("/") ? identifier : nil
                                        )
                                    }
                                    Button(settings.localizedString("btn_cant_quit")) {
                                        let info = resolveAppInfo(for: identifier)
                                        let bundleID = info.bundleID ?? identifier
                                        // Try to find the actual running PID
                                        let pid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.processIdentifier
                                        FeedbackEngine.shared.reportCantQuit(
                                            bundleID: bundleID,
                                            appName: info.name,
                                            pid: pid
                                        )
                                    }
                                } label: {
                                    Text(settings.localizedString("btn_feedback"))
                                        .font(.caption)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .id(identifier)
                            .tag(identifier)
                        }
                    }
                    .listStyle(.inset)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                    
                    // Toolbar with + / -
                    HStack(spacing: 0) {
                        Group {
                            plusButton(proxy: proxy)
                            
                            Divider()
                                .frame(height: 14)
                            
                            Button {
                                if let sel = selection {
                                    if let index = settings.excludedApps.firstIndex(of: sel) {
                                        settings.excludedApps.remove(at: index)
                                        selection = nil
                                    }
                                }
                            } label: {
                                Image(systemName: "minus")
                                    .frame(width: 32, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(selection == nil)
                        }
                        Spacer()
                    }
                    .frame(height: 28)
                    .background(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(Color(NSColor.separatorColor)),
                        alignment: .top
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                }
            }
        }
        .padding()
        .onChange(of: searchText) { _ in
            if let selection, !filteredAppIdentifiers.contains(selection) {
                self.selection = nil
            }
        }
    }

    private var filteredAppIdentifiers: [String] {
        let sortedApps = settings.excludedApps.sorted {
            resolveAppInfo(for: $0).name.localizedStandardCompare(resolveAppInfo(for: $1).name) == .orderedAscending
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedApps }

        return sortedApps.filter { identifier in
            matchesSearch(query: query, identifier: identifier)
        }
    }

    private func matchesSearch(query: String, identifier: String) -> Bool {
        let info = resolveAppInfo(for: identifier)
        let query = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let appName = info.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let bundleID = (info.bundleID ?? identifier).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        return appName.contains(query) || bundleID.contains(query)
    }
    
    @ViewBuilder
    private func plusButton(proxy: ScrollViewProxy) -> some View {
        let menu = Menu {
            let apps = runningApps
            if !apps.isEmpty {
                if #available(macOS 12.0, *) {
                    Section(settings.localizedString("running_apps")) {
                        runningAppsList(apps: apps, proxy: proxy)
                    }
                } else {
                    runningAppsList(apps: apps, proxy: proxy)
                    Divider()
                }
            }
            
            Button(settings.localizedString("btn_browse")) {
                addApp(proxy: proxy)
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 32, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32, height: 24)
        
        #if os(macOS)
        if #available(macOS 12.0, *) {
            menu.menuIndicator(.hidden)
        } else {
            menu
        }
        #else
        menu
        #endif
    }
    
    @ViewBuilder
    private func runningAppsList(apps: [NSRunningApplication], proxy: ScrollViewProxy) -> some View {
        ForEach(apps, id: \.self) { app in
            Button {
                if let path = app.bundleURL?.path {
                    if !settings.excludedApps.contains(path) {
                        settings.excludedApps.append(path)
                        selectAndScroll(to: path, proxy: proxy)
                    }
                }
            } label: {
                let icon = app.icon ?? NSWorkspace.shared.icon(forFileType: "app")
                Label {
                    Text(app.localizedName ?? "Unknown")
                } icon: {
                    Image(nsImage: icon)
                }
            }
        }
    }
    
    private func selectAndScroll(to id: String, proxy: ScrollViewProxy) {
        selection = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
    
    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  let bundleURL = app.bundleURL else { return false }
            
            let path = bundleURL.path
            let bundleID = app.bundleIdentifier
            
            // Filter out apps already in list
            let alreadyInList = settings.excludedApps.contains { existing in
                existing == path || (bundleID != nil && existing == bundleID)
            }
            
            // Filter out ourselves
            let isSelf = bundleID == Bundle.main.bundleIdentifier
            
            return !alreadyInList && !isSelf
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    
    private func addApp(proxy: ScrollViewProxy) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        if panel.runModal() == .OK {
            var lastAdded: String?
            for url in panel.urls {
                if !settings.excludedApps.contains(url.path) {
                    settings.excludedApps.append(url.path)
                    lastAdded = url.path
                }
            }
            if let id = lastAdded {
                selectAndScroll(to: id, proxy: proxy)
            }
        }
    }
    
    private func resolveAppInfo(for id: String) -> (name: String, bundleID: String?) {
        let ws = NSWorkspace.shared
        if id.hasPrefix("/") {
            let name = FileManager.default.displayName(atPath: id)
            let bundle = Bundle(path: id)
            return (name, bundle?.bundleIdentifier)
        }
        if let url = ws.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            return (name, id)
        }
        return (id, id)
    }
}

struct AppListRow: View {
    let identifier: String
    
    var body: some View {
        HStack(spacing: 10) {
            let info = resolveInfo(for: identifier)
            Image(nsImage: info.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
            
            Text(info.name)
                .font(.body)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
    
    private func resolveInfo(for id: String) -> (icon: NSImage, name: String) {
        let ws = NSWorkspace.shared
        
        // 1. If it's a path
        if id.hasPrefix("/") {
            let icon = ws.icon(forFile: id)
            let name = FileManager.default.displayName(atPath: id)
            return (icon, name)
        }
        
        // 2. If it's a Bundle ID
        if let url = ws.urlForApplication(withBundleIdentifier: id) {
            let icon = ws.icon(forFile: url.path)
            let name = FileManager.default.displayName(atPath: url.path)
            return (icon, name)
        }
        
        // 3. Fallback
        let genericIcon = ws.icon(forFileType: "app")
        return (genericIcon, id)
    }
}

struct DataSettingsView: View {
    @ObservedObject var settings: Settings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.localizedString("section_live_monitor"))
                .font(.headline)

            HStack(alignment: .top, spacing: 14) {
                diagnosticsPane
                logsPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private var diagnosticsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(settings.localizedString("diag_performance_title"))
                    .font(.headline)
                Spacer()
                if let updatedAt = settings.watcherDiagnosticsUpdatedAt {
                    Text(Self.diagnosticsDateFormatter.string(from: updatedAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(settings.localizedString("diag_performance_desc"))
                .font(.caption)
                .foregroundColor(.secondary)

            Group {
                if settings.watcherDiagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.localizedString("diag_empty_title"))
                            .font(.subheadline).bold()
                        Text(settings.localizedString("diag_empty_desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(settings.watcherDiagnostics) { row in
                                WatcherDiagnosticCard(settings: settings, row: row)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var logsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.localizedString("section_logs"))
                .font(.headline)

            Text(settings.localizedString("diag_logs_desc"))
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(settings.logs) { entry in
                            if #available(macOS 12.0, *) {
                                Text(entry.line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(logColor(for: entry.tone))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(entry.line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(logColor(for: entry.tone))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("logBottom")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .onChange(of: settings.logs.count) { _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }

            HStack {
                Spacer()
                Button(settings.localizedString("btn_export_logs")) {
                    exportLogs()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Divider()
                    .frame(height: 10)

                Button(settings.localizedString("btn_clear_logs")) {
                    settings.logs.removeAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func exportLogs() {
        let savePanel = NSSavePanel()
        if #available(macOS 11.0, *) {
            savePanel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        } else {
            savePanel.allowedFileTypes = ["log"]
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let dateStr = formatter.string(from: Date())
        savePanel.nameFieldStringValue = "quitty_logs_\(dateStr).log"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            let logContent = settings.exportedLogsText
            try? logContent.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func logColor(for tone: LogTone) -> Color {
        switch tone {
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .red
        case .neutral:
            return .secondary
        }
    }
}

private struct SyncBackupSectionView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(settings.localizedString("icloud_sync"), isOn: $settings.iCloudSyncEnabled)
                    Text(settings.localizedString("icloud_sync_desc"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(settings.localizedString("section_sync"))
            }

            Section {
                HStack {
                    Button(settings.localizedString("btn_export")) {
                        exportSettings()
                    }
                    Button(settings.localizedString("btn_import")) {
                        importSettings()
                    }
                }
            } header: {
                Text(settings.localizedString("section_backup"))
            }
        }
    }

    private func exportSettings() {
        let savePanel = NSSavePanel()
        if #available(macOS 11.0, *) {
            savePanel.allowedContentTypes = [.json]
        } else {
            savePanel.allowedFileTypes = ["json"]
        }
        savePanel.nameFieldStringValue = "quitty_settings.json"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            if let data = settings.exportToJSON() {
                try? data.write(to: url)
            }
        }
    }

    private func importSettings() {
        let openPanel = NSOpenPanel()
        if #available(macOS 11.0, *) {
            openPanel.allowedContentTypes = [.json]
        } else {
            openPanel.allowedFileTypes = ["json"]
        }
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            if let data = try? Data(contentsOf: url) {
                _ = settings.importFromJSON(data: data)
            }
        }
    }
}

private struct WatcherDiagnosticCard: View {
    let settings: Settings
    let row: WatcherDiagnosticRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 10) {
                    DiagnosticAppIcon(row: row)

                    Text(row.appName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Text(settings.localizedString(loadLabelKey))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(loadColor)
            }

            SparklineChart(values: row.loadHistory, tint: loadColor)
                .frame(height: 34)

            Text(detailLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private var totalLoadRatio: Double {
        let combined = row.totalTrackedMs + row.cgChecks * 45 + row.rescueScans * 8 + row.duplicateSkips * 3
        return normalized(value: combined, softCap: 2200)
    }

    private var loadLabelKey: String {
        switch totalLoadRatio {
        case 0..<0.25:
            return "diag_load_good"
        case 0.25..<0.55:
            return "diag_load_ok"
        case 0.55..<0.8:
            return "diag_load_busy"
        default:
            return "diag_load_hot"
        }
    }

    private var loadColor: Color {
        switch totalLoadRatio {
        case 0..<0.25:
            return .green
        case 0.25..<0.55:
            return .yellow
        case 0.55..<0.8:
            return .orange
        default:
            return .red
        }
    }

    private var detailLine: String {
        settings.localizedString("diag_detail_format")
            .replacingOccurrences(of: "%1$@", with: "\(row.axChecks + row.cgChecks)")
            .replacingOccurrences(of: "%2$@", with: "\(row.cgChecks)")
            .replacingOccurrences(of: "%3$@", with: "\(row.rescueScans)")
    }

    private func normalized(value: Int, softCap: Int) -> Double {
        guard softCap > 0 else { return 0 }
        return min(max(Double(value) / Double(softCap), 0), 1)
    }
}

private struct DiagnosticAppIcon: View {
    let row: WatcherDiagnosticRow

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var icon: NSImage {
        let workspace = NSWorkspace.shared

        if let bundlePath = row.bundlePath, !bundlePath.isEmpty {
            return workspace.icon(forFile: bundlePath)
        }

        if let bundleIdentifier = row.bundleIdentifier,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return workspace.icon(forFile: url.path)
        }

        return workspace.icon(forFileType: "app")
    }
}

private struct SparklineChart: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))

                if values.count >= 2 {
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                            let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else {
                    Capsule()
                        .fill(tint.opacity(0.4))
                        .frame(width: geometry.size.width, height: 4)
                        .offset(y: -8)
                }
            }
        }
    }
}

struct HistorySettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var feedback: FeedbackEngine = .shared
    
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.localizedString("section_history"))
                    .font(.headline)
                Spacer()
                if !feedback.history.isEmpty {
                    Button(settings.localizedString("btn_clear_history")) {
                        feedback.history.removeAll()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            
            Text(settings.localizedString("history_desc"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if feedback.history.isEmpty {
                VStack {
                    Spacer()
                    Text(settings.localizedString("history_empty"))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                List {
                    ForEach(feedback.history) { record in
                        HistoryRow(record: record, settings: settings, feedback: feedback, dateFormatter: dateFormatter)
                    }
                }
                .listStyle(.inset)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
        }
        .padding()
    }
}

struct HistoryRow: View {
    let record: TerminationRecord
    @ObservedObject var settings: Settings
    @ObservedObject var feedback: FeedbackEngine
    let dateFormatter: DateFormatter
    
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: feedback.appIcon(for: record))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(record.appName)
                    .font(.body)
                    .lineLimit(1)
                
                Text(dateFormatter.string(from: record.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let ft = record.feedbackType {
                HStack(spacing: 4) {
                    Image(systemName: ft == .falseQuit ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(ft == .falseQuit ? .orange : .green)
                        .font(.caption)
                    Text(settings.localizedString(ft == .falseQuit ? "feedback_false_quit" : "feedback_cant_quit"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button {
                        feedback.undoFeedback(recordID: record.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help(settings.localizedString("btn_undo_feedback"))
                }
            } else {
                Button(settings.localizedString("btn_false_quit")) {
                    feedback.reportFalseQuit(recordID: record.id)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
