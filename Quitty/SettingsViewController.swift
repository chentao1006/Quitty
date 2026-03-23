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
            
            DataSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_data"), systemImage: "externaldrive")
                }
                .tag(2)
            
            AboutSettingsView(settings: settings)
                .tabItem {
                    Label(settings.localizedString("tab_about"), systemImage: "info.circle")
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
        #if os(macOS)
        if #available(macOS 13.0, *) {
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
            }
            .formStyle(.grouped)
        } else {
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
            }
        }
        #endif
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
                                .frame(width: 32, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
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
        #if os(macOS)
        if #available(macOS 13.0, *) {
            formBody.formStyle(.grouped)
        } else {
            formBody
        }
        #else
        formBody
        #endif
    }
    
    private var formBody: some View {
        Form {
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

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                #if os(macOS)
                                if #available(macOS 12.0, *) {
                                    Text(settings.logs.joined(separator: "\n"))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(settings.logs.joined(separator: "\n"))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                #endif
                                
                                Color.clear
                                    .frame(height: 1)
                                    .id("logBottom")
                            }
                        }
                        .frame(height: 200)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
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
                .padding(.vertical, 4)
            } header: {
                Text(settings.localizedString("section_logs"))
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
            let logContent = settings.logs.joined(separator: "\n")
            try? logContent.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
