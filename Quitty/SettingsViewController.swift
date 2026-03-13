import SwiftUI
import Cocoa

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
            
            DataSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_data"), systemImage: "externaldrive")
                }
                .tag(2)
            
            TroubleshootingSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_troubleshooting"), systemImage: "bolt.shield")
                }
                .tag(3)
        }
        // Force redraw on language change AND force a wide layout to prevent collapse
        .id(settings.appLanguage)
        .frame(minWidth: 650, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: Settings
    
    var body: some View {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(settings.localizedString("quit_delay")): \(String(format: "%.1f", settings.closeDelay))s")
                        .font(.body)
                    Slider(value: $settings.closeDelay, in: 0...5, step: 0.1)
                }
                .padding(.vertical, 4)
            } header: {
                Text(settings.localizedString("section_behavior"))
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
                
                Button(settings.localizedString(settings.isAccessibilityAuthorized ? "btn_check" : "btn_grant")) {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.checkAccessibilityPermissions(silent: false)
                        settings.objectWillChange.send()
                    }
                }
            } header: {
                Text(settings.localizedString("section_permissions"))
            }
        }
        .formStyle(.grouped)
    }
}

struct TroubleshootingSettingsView: View {
    @ObservedObject var settings: Settings
    @State private var isRunningDiagnostic = false
    @State private var diagnosticResult = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(settings.logs.indices, id: \.self) { index in
                                    Text(settings.logs[index])
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(8)
                        }
                        .frame(minHeight: 200, maxHeight: 300)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                        .onChange(of: settings.logs.count) { _ in
                            if let last = settings.logs.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                    
                    HStack {
                        Spacer()
                        Button(settings.localizedString("btn_clear_logs")) {
                            settings.logs.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            } header: {
                Text(settings.localizedString("section_logs"))
            }

            Section {
                Button {
                    runDiagnostic()
                } label: {
                    HStack {
                        Text(settings.localizedString("btn_diagnostic"))
                        if isRunningDiagnostic {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isRunningDiagnostic)
                
                if !diagnosticResult.isEmpty {
                    Text(diagnosticResult)
                        .font(.caption)
                        .foregroundColor(diagnosticResult.contains("...") ? .orange : .secondary)
                }
            } header: {
                Text(settings.localizedString("section_troubleshooting"))
            }
        }
        .formStyle(.grouped)
    }

    private func runDiagnostic() {
        isRunningDiagnostic = true
        diagnosticResult = ""
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let delegate = NSApplication.shared.delegate as? AppDelegate else {
                isRunningDiagnostic = false
                return
            }
            
            let status = delegate.checkHealthAndFix()
            if status == "restart" {
                diagnosticResult = settings.localizedString("diagnostic_restarting")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    delegate.relaunch()
                }
            } else if status == "ok" {
                diagnosticResult = settings.localizedString("diagnostic_ok")
                isRunningDiagnostic = false
            } else {
                diagnosticResult = status // Likely "Not Authorized"
                isRunningDiagnostic = false
            }
        }
    }
}

struct AppListSettingsView: View {
    @ObservedObject var settings: Settings
    @State private var selection: String?
    
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
            
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.excludedApps, id: \.self) { identifier in
                        AppListRow(identifier: identifier)
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
                        Button {
                            addApp()
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.plain)
                        
                        Divider()
                            .frame(height: 12)
                        
                        Button {
                            if let sel = selection {
                                if let index = settings.excludedApps.firstIndex(of: sel) {
                                    settings.excludedApps.remove(at: index)
                                    selection = nil
                                }
                            }
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(selection == nil)
                    }
                    Spacer()
                }
                .frame(height: 24)
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
        .padding()
    }
    
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !settings.excludedApps.contains(url.path) {
                    settings.excludedApps.append(url.path)
                }
            }
        }
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
            let url = URL(fileURLWithPath: id)
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
        Form {
            Section {
                Toggle(settings.localizedString("file_sync"), isOn: $settings.fileSyncEnabled)
                
                if settings.fileSyncEnabled {
                    HStack {
                        Text(settings.localizedString("sync_path"))
                        Text(settings.syncFilePath)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(settings.localizedString("btn_choose")) {
                            chooseSyncPath()
                        }
                    }
                }
            } header: {
                Text(settings.localizedString("tab_data"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    private func chooseSyncPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.syncFilePath)
        
        if panel.runModal() == .OK, let url = panel.url {
            settings.syncFilePath = url.path
        }
    }
}
