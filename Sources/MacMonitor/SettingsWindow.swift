import AppKit
import SwiftUI
import ServiceManagement
import MacMonitorCore

/// Launch at Login via SMAppService (only works from the .app bundle).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor
    static func set(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            let bundled = Bundle.main.bundleURL.pathExtension == "app"
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = bundled
                ? "\(error.localizedDescription)\n\nTry moving MacMonitor.app to /Applications, or add it manually in System Settings → General → Login Items."
                : "Launch at Login only works when MacMonitor runs from the bundled MacMonitor.app (use build_app.sh)."
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    #if APPSTORE
    init(prefs: Preferences, alerts: AlertManager, remotes: RemoteManager) {
        let view = SettingsView(prefs: prefs, alerts: alerts, remotes: remotes)
        super.init(window: Self.makeWindow(NSHostingController(rootView: view)))
    }
    #else
    init(prefs: Preferences, alerts: AlertManager, remotes: RemoteManager, updates: UpdateChecker) {
        let view = SettingsView(prefs: prefs, alerts: alerts, remotes: remotes, updates: updates)
        super.init(window: Self.makeWindow(NSHostingController(rootView: view)))
    }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makeWindow(_ vc: NSViewController) -> NSWindow {
        let w = NSWindow(contentViewController: vc)
        w.title = "MacMonitor Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 560, height: 480))
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { NotificationCenter.default.post(name: .selectSettingsTab, object: tab.rawValue) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let selectSettingsTab = Notification.Name("MacMonitorSelectSettingsTab")
}

enum SettingsTab: String { case general, panel, alerts, servers }

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let alerts: AlertManager
    @ObservedObject var remotes: RemoteManager
    #if !APPSTORE
    @ObservedObject var updates: UpdateChecker
    #endif
    @State private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general.rawValue)
            panel.tabItem { Label("Desktop Panel", systemImage: "rectangle.on.rectangle") }.tag(SettingsTab.panel.rawValue)
            alertsTab.tabItem { Label("Alerts", systemImage: "bell") }.tag(SettingsTab.alerts.rawValue)
            ServersSettings(remotes: remotes).tabItem { Label("Servers", systemImage: "server.rack") }
                .tag(SettingsTab.servers.rawValue)
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .environment(\.layoutDirection, InterfaceDirection.isRightToLeft(Locale.preferredLanguages) ? .rightToLeft : .leftToRight)
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsTab)) { note in
            if let t = note.object as? String { tab = t }
        }
    }

    // MARK: General

    @State private var launchAtLogin = LoginItem.isEnabled

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { v in
                    LoginItem.set(v)
                    launchAtLogin = LoginItem.isEnabled
                }))
            }
            Section("Menu bar") {
                Picker("Style", selection: $prefs.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                ForEach(availableMenuItems) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { prefs.menuBarItems.contains(item) },
                        set: { on in if on { prefs.menuBarItems.insert(item) } else { prefs.menuBarItems.remove(item) } }))
                }
            }
            Section("Sampling") {
                Picker("Update every", selection: $prefs.updateInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds (saves energy)").tag(5.0)
                }
            }
            #if !APPSTORE
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $prefs.checkForUpdates)
                HStack {
                    Text("Version \(UpdateChecker.currentVersion)")
                        .foregroundColor(.secondary)
                    if let a = updates.available {
                        Button("Download \(a.version)") { NSWorkspace.shared.open(a.url) }
                    }
                    Spacer()
                    Button("Check Now") { updates.check(userInitiated: true) }
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }

    private var availableMenuItems: [MenuBarItem] {
        #if APPSTORE
        return MenuBarItem.allCases.filter { $0 != .temperature }
        #else
        return MenuBarItem.allCases
        #endif
    }

    // MARK: Panel

    private var panel: some View {
        Form {
            Section("Look") {
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(PanelTheme.allCases) { Text($0.label).tag($0) }
                }
                Picker("Size", selection: $prefs.size) {
                    ForEach(PanelSize.allCases) { Text($0.label).tag($0) }
                }
                Picker("Position", selection: $prefs.corner) {
                    ForEach(PanelCorner.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Sections") {
                ForEach(PanelSection.allCases.filter { !hiddenSection($0) }) { s in
                    Toggle(s.label, isOn: Binding(
                        get: { prefs.sections.contains(s) },
                        set: { on in if on { prefs.sections.insert(s) } else { prefs.sections.remove(s) } }))
                }
                Text("Temperatures and fans are read from the SMC and are best-effort: some Mac models report nothing. Top processes only include your own processes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func hiddenSection(_ s: PanelSection) -> Bool {
        #if APPSTORE
        return s.directOnly
        #else
        return false
        #endif
    }

    // MARK: Alerts

    private var alertsTab: some View {
        Form {
            Section {
                Toggle("Send notifications", isOn: Binding(get: { prefs.alerts.enabled }, set: { on in
                    prefs.alerts.enabled = on
                    if on { alerts.requestAuthorization() }
                }))
                Button("Send a Test Notification") { alerts.sendTest() }
                    .disabled(!prefs.alerts.enabled)
            }
            Section("This Mac") {
                percentStepper("CPU above", value: $prefs.alerts.cpuPercent)
                minutesStepper("…for at least", value: $prefs.alerts.cpuMinutes)
                Toggle("Critical memory pressure", isOn: $prefs.alerts.memoryPressure)
                percentStepper("Disk fuller than", value: $prefs.alerts.diskPercent)
                percentStepper("Battery below", value: $prefs.alerts.batteryPercent)
            }
            Section("Servers") {
                minutesStepper("Unreachable for", value: $prefs.alerts.serverOfflineMinutes)
                percentStepper("CPU above", value: $prefs.alerts.serverCPUPercent)
                minutesStepper("…for at least", value: $prefs.alerts.serverCPUMinutes)
                percentStepper("Filesystem fuller than", value: $prefs.alerts.serverDiskPercent)
                Toggle("Watched service stops", isOn: $prefs.alerts.services)
                Toggle("Reboot required", isOn: $prefs.alerts.reboot)
            }
        }
        .formStyle(.grouped)
        .disabled(false)
    }

    private func percentStepper(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: 5...100, step: 5) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))%").monospacedDigit() }
        }
    }

    private func minutesStepper(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: 1...60, step: 1) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue)) min").monospacedDigit() }
        }
    }
}

// MARK: - Servers

struct ServersSettings: View {
    @ObservedObject var remotes: RemoteManager

    #if APPSTORE
    static let emptyHint = "Add a Linux or Mac server. MacMonitor logs in with a private key file or a password, both kept in your Keychain."
    #else
    static let emptyHint = "Add a Linux or Mac server that accepts SSH key login, or import hosts from ~/.ssh/config."
    #endif
    @State private var importing = false
    @State private var candidates: [SSHHostEntry] = []
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if remotes.servers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.largeTitle).foregroundColor(.secondary)
                    Text("No servers yet").font(.headline)
                    Text(Self.emptyHint)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(remotes.servers.enumerated()), id: \.element.id) { index, server in
                        ServerRow(server: server, index: index, count: remotes.servers.count, remotes: remotes)
                    }
                }
            }
            HStack {
                Button("Add Server…") {
                    if let r = ServerEditor.run() { remotes.add(r.config) }
                }
                #if !APPSTORE
                Button("Import from ~/.ssh/config…") {
                    candidates = SSHConfigImporter.load().filter { e in
                        !remotes.servers.contains { $0.config.host == e.alias }
                    }
                    selected = Set(candidates.map(\.alias))
                    importing = true
                }
                #endif
                Spacer()
            }
        }
        .sheet(isPresented: $importing) { importSheet }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from ~/.ssh/config").font(.headline)
            if candidates.isEmpty {
                Text("No new Host entries were found (wildcard patterns are skipped).")
                    .foregroundColor(.secondary)
            } else {
                List(candidates) { e in
                    Toggle(isOn: Binding(get: { selected.contains(e.alias) },
                                         set: { on in if on { selected.insert(e.alias) } else { selected.remove(e.alias) } })) {
                        VStack(alignment: .leading) {
                            Text(e.alias)
                            Text([e.user.map { $0 + "@" }, e.hostName ?? e.alias, e.port.map { ":\($0)" }]
                                .compactMap { $0 }.joined())
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button("Cancel") { importing = false }
                Button("Import \(selected.count)") {
                    remotes.importServers(candidates.filter { selected.contains($0.alias) }.map { $0.serverConfig() })
                    importing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct ServerRow: View {
    @ObservedObject var server: RemoteSampler
    let index: Int
    let count: Int
    let remotes: RemoteManager

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.config.name).font(.body.weight(.medium))
                Text(server.config.displayAddress + (server.config.services.isEmpty ? ""
                     : " · " + server.config.services.joined(separator: ", ")))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("Compact", isOn: Binding(get: { server.config.collapsed }, set: { v in
                var c = server.config; c.collapsed = v; remotes.update(c)
            }))
            .toggleStyle(.checkbox)
            Toggle("Hide disks", isOn: Binding(get: { server.config.hideDisks }, set: { v in
                var c = server.config; c.hideDisks = v; remotes.update(c)
            }))
            .toggleStyle(.checkbox)
            Button { remotes.move(id: server.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).buttonStyle(.borderless)
            Button { remotes.move(id: server.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1).buttonStyle(.borderless)
            Button("Edit…") {
                if let r = ServerEditor.run(editing: server.config) {
                    remotes.update(r.config, secretsChanged: r.secretsChanged)
                }
            }
            Button(role: .destructive) { remotes.remove(id: server.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch server.status {
        case .online: return .green
        case .connecting: return .orange
        case .error: return .red
        }
    }
}
