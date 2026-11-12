import AppKit
import Combine
import MacMonitorCore

@main
enum MacMonitorMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)      // no Dock icon, no app menu
        withExtendedLifetime(delegate) {         // NSApplication.delegate is weak
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Keys {
        static let visible = "panelVisible"
        static let locked = "panelLocked"
    }

    private let prefs = Preferences.shared
    private var sampler: Sampler!
    private var remotes: RemoteManager!
    #if !APPSTORE
    private var updates: UpdateChecker!
    #endif
    private var panel: DesktopPanel!
    private var statusItem: NSStatusItem!
    private var alerts: AlertManager!
    private let widgetBridge = WidgetBridge()
    private var settings: SettingsWindowController?
    private var subs: Set<AnyCancellable> = []

    private var showItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var serversItem: NSMenuItem!
    #if !APPSTORE
    private var updateItem: NSMenuItem!
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Keys.visible: true, Keys.locked: true])
        let snapshotMode = SnapshotExporter.isActive

        sampler = Sampler(prefs: prefs)
        alerts = AlertManager(prefs: prefs)
        // Snapshot debug mode shows a fake 'linux-server' instead of connecting over SSH.
        remotes = RemoteManager(demo: snapshotMode)
        #if !APPSTORE
        updates = UpdateChecker(prefs: prefs)
        #endif
        panel = DesktopPanel(sampler: sampler, remotes: remotes, prefs: prefs)
        panel.locked = UserDefaults.standard.bool(forKey: Keys.locked)
        if UserDefaults.standard.bool(forKey: Keys.visible) && !snapshotMode { panel.orderFront(nil) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = "CPU --  RAM --"
            button.toolTip = AppDisplay.name
            button.setAccessibilityLabel(AppDisplay.name)
            button.imagePosition = .imageLeft
        }
        statusItem.menu = buildMenu()

        sampler.onTick = { [weak self] s in self?.tick(s) }
        tick(sampler.snapshot)
        // Redraw the title right away when menu bar settings change.
        prefs.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem(self?.sampler.snapshot) } }
            .store(in: &subs)

        SnapshotExporter.scheduleIfRequested(sampler: sampler, remotes: remotes, prefs: prefs)
    }

    // MARK: Tick

    private func tick(_ s: Snapshot) {
        updateStatusItem(s)

        var input = AlertInput()
        input.cpu = s.cpu
        input.memoryPressureCritical = s.memory.pressure == .critical
        input.volumes = s.volumes.map { .init(id: $0.id, name: $0.name, usedFraction: $0.usedFraction) }
        input.batteryPercent = s.battery?.percent
        input.batteryCharging = s.battery.map { $0.charging || $0.onAC } ?? false
        input.servers = remotes.servers.map { srv in
            var offline = false
            if case .error = srv.status { offline = true }
            let snap = srv.snapshot
            return AlertInput.Server(id: srv.id, name: srv.config.name, offline: offline,
                                     online: srv.status == .online && snap.hasData, cpu: snap.cpu,
                                     disks: snap.disks, services: snap.services,
                                     rebootRequired: snap.rebootRequired == true)
        }
        widgetBridge.update(servers: remotes.servers.map(\.widgetServer))
        alerts.evaluate(input)
    }

    private func updateStatusItem(_ s: Snapshot?) {
        guard let s, let button = statusItem?.button else { return }
        let title = MenuBarRenderer.title(for: s, items: prefs.menuBarItems)
        if button.title != title { button.title = title }
        if prefs.menuBarStyle == .graph {
            button.image = MenuBarRenderer.sparkline(s.cpuHistory)
        } else if button.image != nil {
            button.image = nil
        }
    }

    // MARK: URL scheme (macmonitor://settings, used by the widget)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "macmonitor" {
            switch url.host {
            case "servers": showSettings(tab: .servers)
            case "panel":
                if !panel.isVisible { toggleVisible() }
            default: showSettings(tab: nil)
            }
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: AppDisplay.name)
        menu.delegate = self
        menu.autoenablesItems = false
        let brand = NSMenuItem(title: AppDisplay.name, action: nil, keyEquivalent: "")
        brand.isEnabled = false
        menu.addItem(brand)
        menu.addItem(item("About \(AppDisplay.name)", #selector(showAbout)))
        menu.addItem(.separator())
        showItem = item("Hide Desktop Panel", #selector(toggleVisible))
        lockItem = item("Unlock Position", #selector(toggleLock))
        loginItem = item("Launch at Login", #selector(toggleLogin))
        [showItem, lockItem, loginItem].forEach { menu.addItem($0!) }
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Add Server…", #selector(addServer)))
        #if !APPSTORE
        menu.addItem(item("Import from ~/.ssh/config…", #selector(importServers)))
        #endif
        serversItem = NSMenuItem(title: "Servers", action: nil, keyEquivalent: "")
        serversItem.submenu = NSMenu(title: "Servers")
        menu.addItem(serversItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Activity Monitor", #selector(openActivityMonitor)))
        menu.addItem(item("Open Disk Utility", #selector(openDiskUtility)))
        #if !APPSTORE
        menu.addItem(.separator())
        updateItem = item("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(updateItem)
        #endif
        menu.addItem(.separator())
        menu.addItem(item("Quit \(AppDisplay.name)", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showItem.title = panel.isVisible ? "Hide Desktop Panel" : "Show Desktop Panel"
        lockItem.title = panel.locked ? "Unlock Position" : "Lock Position"
        lockItem.isEnabled = panel.isVisible
        loginItem.state = LoginItem.isEnabled ? .on : .off
        rebuildServersMenu()
        #if !APPSTORE
        if let a = updates.available {
            updateItem.title = "Update Available: \(a.version)…"
        } else {
            updateItem.title = "Check for Updates…"
        }
        #endif
    }

    @objc private func openSettings() { showSettings(tab: nil) }

    private func showSettings(tab: SettingsTab?) {
        if settings == nil {
            #if APPSTORE
            settings = SettingsWindowController(prefs: prefs, alerts: alerts, remotes: remotes)
            #else
            settings = SettingsWindowController(prefs: prefs, alerts: alerts, remotes: remotes, updates: updates)
            #endif
        }
        settings?.show(tab: tab)
    }

    @objc private func openActivityMonitor() { openApp(bundleID: "com.apple.ActivityMonitor") }
    @objc private func openDiskUtility() { openApp(bundleID: "com.apple.DiskUtility") }

    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func applicationWillTerminate(_ notification: Notification) {
        remotes?.stopAll()          // end every SSH session so none are left behind
    }

    #if !APPSTORE
    @objc private func checkForUpdates() {
        if let a = updates.available {
            NSWorkspace.shared.open(a.url)
        } else {
            updates.check(userInitiated: true)
        }
    }
    #endif

    // MARK: Servers

    private func rebuildServersMenu() {
        guard let sub = serversItem.submenu else { return }
        sub.removeAllItems()
        sub.autoenablesItems = false
        let servers = remotes.servers
        serversItem.isEnabled = !servers.isEmpty
        serversItem.title = servers.isEmpty ? "Servers" : "Servers (\(servers.count))"
        for server in servers {
            let entry = NSMenuItem(title: server.config.name, action: nil, keyEquivalent: "")
            let detail = NSMenu()
            detail.autoenablesItems = false
            let info = NSMenuItem(title: server.config.displayAddress + " · " + Self.describe(server.status),
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            detail.addItem(info)
            for w in WidgetServer.warnings(for: server.snapshot) {
                let wi = NSMenuItem(title: "⚠︎ " + w, action: nil, keyEquivalent: "")
                wi.isEnabled = false
                detail.addItem(wi)
            }
            detail.addItem(.separator())
            func add(_ title: String, _ action: Selector) {
                let i = item(title, action)
                i.representedObject = server.id
                detail.addItem(i)
            }
            add("Open SSH in Terminal", #selector(openSSH(_:)))
            add("Copy SSH Command", #selector(copySSH(_:)))
            detail.addItem(.separator())
            add("Edit…", #selector(editServer(_:)))
            add(server.config.collapsed ? "Expand in Panel" : "Compact in Panel", #selector(toggleCollapsed(_:)))
            if server.hostKeyMismatch { add("Trust New Host Key", #selector(trustHostKey(_:))) }
            add("Reconnect", #selector(reconnectServer(_:)))
            add("Remove", #selector(removeServer(_:)))
            entry.submenu = detail
            sub.addItem(entry)
        }
        if !servers.isEmpty {
            sub.addItem(.separator())
            sub.addItem(item("Manage Servers…", #selector(manageServers)))
        }
    }

    private static func describe(_ status: RemoteStatus) -> String {
        switch status {
        case .connecting: return "connecting"
        case .online: return "online"
        case .error: return "error"
        }
    }

    private func server(_ sender: NSMenuItem) -> RemoteSampler? {
        (sender.representedObject as? UUID).flatMap { remotes.server(id: $0) }
    }

    @objc private func removeServer(_ sender: NSMenuItem) {
        guard let s = server(sender) else { return }
        remotes.remove(id: s.id)
    }

    @objc private func reconnectServer(_ sender: NSMenuItem) { server(sender)?.reconnect() }

    @objc private func editServer(_ sender: NSMenuItem) {
        guard let s = server(sender), let r = ServerEditor.run(editing: s.config) else { return }
        remotes.update(r.config, secretsChanged: r.secretsChanged)
    }

    @objc private func trustHostKey(_ sender: NSMenuItem) {
        guard let s = server(sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Trust the new host key of \(s.config.name)?"
        alert.informativeText = "Only do this if you know the server was reinstalled or its SSH keys were "
            + "regenerated. Otherwise someone may be intercepting the connection."
        alert.addButton(withTitle: "Trust New Key")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remotes.trustNewHostKey(id: s.id)
    }

    @objc private func toggleCollapsed(_ sender: NSMenuItem) {
        guard var cfg = server(sender)?.config else { return }
        cfg.collapsed.toggle()
        remotes.update(cfg)
    }

    @objc private func openSSH(_ sender: NSMenuItem) {
        guard let url = server(sender)?.config.sshURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copySSH(_ sender: NSMenuItem) {
        guard let cmd = server(sender)?.config.sshCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    @objc private func addServer() {
        if let r = ServerEditor.run() { remotes.add(r.config) }
    }

    @objc private func importServers() { showSettings(tab: .servers) }
    @objc private func manageServers() { showSettings(tab: .servers) }

    @objc private func toggleVisible() {
        let show = !panel.isVisible
        if show { panel.orderFront(nil) } else { panel.orderOut(nil) }
        UserDefaults.standard.set(show, forKey: Keys.visible)
    }

    @objc private func toggleLock() {
        panel.locked.toggle()
        UserDefaults.standard.set(panel.locked, forKey: Keys.locked)
    }

    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isEnabled) }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = AppDisplay.name
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        alert.informativeText = version.isEmpty ? "" : "Version \(version) (\(build))"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
