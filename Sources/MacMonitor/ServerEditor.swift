#if !APPSTORE
import AppKit
import Darwin
import MacMonitorCore

/// Add / edit form shown as a modal alert (works from the menu bar without a window).
@MainActor
enum ServerEditor {
    /// Returns the new or edited config, or nil when cancelled / invalid.
    static func run(editing existing: ServerConfig? = nil) -> ServerConfig? {
        func field(_ placeholder: String, _ value: String = "") -> NSTextField {
            let f = NSTextField(string: value)
            f.placeholderString = placeholder
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return f
        }
        let e = existing
        let nameField = field("e.g. web-01 (optional)", e?.name ?? "")
        let hostField = field("hostname, IP or ~/.ssh/config alias", e?.host ?? "")
        let userField = field("user (empty = from ~/.ssh/config)", e?.user ?? NSUserName())
        let portField = field("22", String(e?.port ?? 22))
        let keyField = field("~/.ssh/id_ed25519 (optional)", e?.identityFile ?? "")
        let servicesField = field("nginx postgresql (optional)", e?.services.joined(separator: " ") ?? "")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Host:"), hostField],
            [NSTextField(labelWithString: "User:"), userField],
            [NSTextField(labelWithString: "Port:"), portField],
            [NSTextField(labelWithString: "Identity file:"), keyField],
            [NSTextField(labelWithString: "Services:"), servicesField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Server" : "Edit \(existing!.name)"
        alert.informativeText = """
            MacMonitor connects with /usr/bin/ssh using key authentication (no passwords). \
            Set up a key first: ssh-copy-id user@host. Linux and macOS servers are supported. \
            Services are systemd units to watch (Linux), separated by spaces.
            """
        alert.accessoryView = grid
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        let order = [nameField, hostField, userField, portField, keyField, servicesField]
        for (i, f) in order.enumerated() { f.nextKeyView = order[(i + 1) % order.count] }
        alert.window.initialFirstResponder = hostField

        NSApp.activate(ignoringOtherApps: true)   // accessory app: bring the alert to the front
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let trim: (NSTextField) -> String = { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let host = trim(hostField), user = trim(userField), key = trim(keyField)
        let portText = trim(portField)
        let port = portText.isEmpty ? 22 : (Int(portText) ?? -1)
        var name = trim(nameField)
        if name.isEmpty { name = host }
        let services = trim(servicesField).split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)

        var problem: String?
        if host.isEmpty { problem = "Enter a host name or IP address." }
        else if !ServerConfig.isSafeArgument(host) { problem = "The host can't start with '-' or contain spaces, quotes or '@'." }
        else if !user.isEmpty && !ServerConfig.isSafeArgument(user) { problem = "The user name can't start with '-' or contain spaces, quotes or '@'." }
        else if !(1...65535).contains(port) { problem = "The port must be a number from 1 to 65535." }
        else if let bad = services.first(where: { !ServerConfig.isValidServiceName($0) }) {
            problem = "“\(bad)” isn't a valid service name (letters, digits, - _ . @ : only)."
        }
        if let problem {
            let err = NSAlert()
            err.messageText = existing == nil ? "Couldn't add server" : "Couldn't save server"
            err.informativeText = problem
            err.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            err.runModal()
            return nil
        }
        var cfg = existing ?? ServerConfig(name: name, host: host, user: user)
        cfg.name = name
        cfg.host = host
        cfg.user = user
        cfg.port = port
        cfg.identityFile = key.isEmpty ? nil : key
        cfg.services = services
        return cfg
    }
}

/// Reads ~/.ssh/config (following Include lines) for the importer.
enum SSHConfigImporter {
    static var sshDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh") }

    static func load() -> [SSHHostEntry] {
        let url = sshDir.appendingPathComponent("config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return SSHConfigParser.parse(text, include: resolveInclude)
    }

    /// `Include` takes space-separated paths/globs, relative to ~/.ssh unless absolute or ~.
    private static func resolveInclude(_ arg: String) -> [String] {
        var texts: [String] = []
        for raw in arg.split(separator: " ") {
            var pattern = (String(raw) as NSString).expandingTildeInPath
            if !pattern.hasPrefix("/") { pattern = sshDir.appendingPathComponent(pattern).path }
            for path in glob(pattern) {
                if let t = try? String(contentsOfFile: path, encoding: .utf8) { texts.append(t) }
            }
        }
        return texts
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { i in g.gl_pathv[i].map { String(cString: $0) } }
    }
}
#endif
