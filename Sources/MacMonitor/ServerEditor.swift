import AppKit
import Darwin
import MacMonitorCore
import MacMonitorSSH

/// Add / edit form shown as a modal alert (works from the menu bar without a window).
@MainActor
enum ServerEditor {
    struct Result {
        var config: ServerConfig
        /// Keychain secrets were added or replaced (the session must reconnect to use them).
        var secretsChanged: Bool
    }

    /// Auth methods offered by this edition.
    static var availableAuth: [SSHAuthKind] {
        #if APPSTORE
        return [.key, .password]
        #else
        return [.system, .key, .password]
        #endif
    }

    /// Returns the new or edited config, or nil when cancelled / invalid.
    static func run(editing existing: ServerConfig? = nil) -> Result? {
        let form = EditorForm(existing: existing)
        var problem: String?
        repeat {
            if let problem { form.showProblem(problem) }
            guard form.runModal() else { return nil }
            problem = form.validate()
        } while problem != nil
        return form.save()
    }
}

/// Owns the controls of the editor and reacts to the auth popup / "Choose…" button.
@MainActor
private final class EditorForm: NSObject {
    private let existing: ServerConfig?
    private let id: UUID
    private let alert = NSAlert()

    private let nameField: NSTextField
    private let hostField: NSTextField
    private let userField: NSTextField
    private let portField: NSTextField
    private let servicesField: NSTextField
    private let jumpHostField: NSTextField
    private let jumpUserField: NSTextField
    private let jumpPortField: NSTextField
    private let agentCheck = NSButton(checkboxWithTitle: "Use ssh-agent (built-in client, outside the sandbox)", target: nil, action: nil)
    private let authPopup = NSPopUpButton()
    // .system
    private let identityField: NSTextField
    // .key
    private let keyLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "Choose Key File…", target: nil, action: nil)
    private let passphraseField = NSSecureTextField()
    // .password
    private let passwordField = NSSecureTextField()
    private var grid: NSGridView!

    private var pickedKey: String?            // contents of a newly chosen key file
    private var pickedKeyName: String?

    init(existing: ServerConfig?) {
        self.existing = existing
        self.id = existing?.id ?? UUID()
        func field(_ placeholder: String, _ value: String = "") -> NSTextField {
            let f = NSTextField(string: value)
            f.placeholderString = placeholder
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 250).isActive = true
            return f
        }
        let e = existing
        nameField = field("e.g. web-01 (optional)", e?.name ?? "")
        hostField = field("hostname or IP", e?.host ?? "")
        userField = field("user name", e?.user ?? NSUserName())
        portField = field("22", String(e?.port ?? 22))
        servicesField = field("nginx postgresql (optional, Linux)", e?.services.joined(separator: " ") ?? "")
        jumpHostField = field("bastion (optional)", e?.jumpHost ?? "")
        jumpUserField = field("jump user (optional)", e?.jumpUser ?? "")
        jumpPortField = field("22", e.map { String($0.jumpPort) } ?? "22")
        agentCheck.state = (e?.useAgent ?? false) ? .on : .off
        identityField = field("~/.ssh/id_ed25519 (optional)", e?.identityFile ?? "")
        super.init()

        for f in [passphraseField, passwordField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }
        passphraseField.placeholderString = existing.map { ServerSecrets.has($0.id, .passphrase) ? "•••• (saved)" : "only if the key has one" } ?? "only if the key has one"
        passwordField.placeholderString = existing.map { ServerSecrets.has($0.id, .password) ? "•••• (saved — leave empty to keep)" : "" } ?? ""

        for kind in ServerEditor.availableAuth { authPopup.addItem(withTitle: kind.label) }
        let current = existing?.auth ?? ServerEditor.availableAuth[0]
        if let i = ServerEditor.availableAuth.firstIndex(of: current) { authPopup.selectItem(at: i) }
        authPopup.target = self
        authPopup.action = #selector(authChanged)
        chooseButton.target = self
        chooseButton.action = #selector(chooseKey)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingMiddle
        let hasKey = existing.map { ServerSecrets.has($0.id, .privateKey) } ?? false
        keyLabel.stringValue = hasKey ? "Key saved in Keychain" : "No key chosen"

        let keyRow = NSStackView(views: [chooseButton, keyLabel])
        keyRow.spacing = 8
        grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Host:"), hostField],
            [NSTextField(labelWithString: "User:"), userField],
            [NSTextField(labelWithString: "Port:"), portField],
            [NSTextField(labelWithString: "Login:"), authPopup],
            [NSTextField(labelWithString: "Identity file:"), identityField],
            [NSTextField(labelWithString: "Private key:"), keyRow],
            [NSTextField(labelWithString: "Passphrase:"), passphraseField],
            [NSTextField(labelWithString: "Password:"), passwordField],
            [NSTextField(labelWithString: "Services:"), servicesField],
            [NSTextField(labelWithString: "Jump host:"), jumpHostField],
            [NSTextField(labelWithString: "Jump user:"), jumpUserField],
            [NSTextField(labelWithString: "Jump port:"), jumpPortField],
            [NSTextField(labelWithString: ""), agentCheck],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        alert.messageText = existing == nil ? "Add Server" : "Edit \(existing!.name)"
        alert.accessoryView = grid
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = hostField
        authChanged()
    }

    private var selectedAuth: SSHAuthKind {
        ServerEditor.availableAuth[max(0, authPopup.indexOfSelectedItem)]
    }

    @objc private func authChanged() {
        let auth = selectedAuth
        grid.row(at: 5).isHidden = auth != .system
        grid.row(at: 6).isHidden = auth != .key
        grid.row(at: 7).isHidden = auth != .key
        grid.row(at: 8).isHidden = auth != .password
        switch auth {
        case .system:
            alert.informativeText = "Uses /usr/bin/ssh with your keys, ssh-agent and ~/.ssh/config (ProxyJump etc.). "
                + "Set up key login first: ssh-copy-id user@host."
        case .key:
            alert.informativeText = "Uses the built-in SSH client. Choose an OpenSSH ed25519 or RSA private key "
                + "(e.g. ~/.ssh/id_ed25519). It's copied into your Keychain."
        case .password:
            alert.informativeText = "Uses the built-in SSH client with a password stored in your Keychain. "
                + "Key login is more secure if the server allows it."
        }
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.layout()
    }

    @objc private func chooseKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose your SSH private key (not the .pub file)"
        panel.prompt = "Use Key"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            keyLabel.stringValue = "Couldn't read \(url.lastPathComponent)"
            return
        }
        if text.hasPrefix("ssh-") || url.pathExtension == "pub" {
            keyLabel.stringValue = "That's a public key — choose the file without .pub"
            return
        }
        pickedKey = text
        pickedKeyName = url.lastPathComponent
        keyLabel.stringValue = url.lastPathComponent
    }

    func runModal() -> Bool {
        NSApp.activate(ignoringOtherApps: true)   // accessory app: bring the alert to the front
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showProblem(_ text: String) {
        let err = NSAlert()
        err.messageText = existing == nil ? "Couldn't add server" : "Couldn't save server"
        err.informativeText = text
        err.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        err.runModal()
    }

    private func trim(_ f: NSTextField) -> String { f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var services: [String] {
        trim(servicesField).split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }

    /// Returns a problem description, or nil when the form is valid.
    func validate() -> String? {
        let host = trim(hostField), user = trim(userField), portText = trim(portField)
        let port = portText.isEmpty ? 22 : (Int(portText) ?? -1)
        if host.isEmpty { return "Enter a host name or IP address." }
        if !ServerConfig.isSafeArgument(host) { return "The host can't start with '-' or contain spaces, quotes or '@'." }
        if !user.isEmpty && !ServerConfig.isSafeArgument(user) {
            return "The user name can't start with '-' or contain spaces, quotes or '@'."
        }
        if !(1...65535).contains(port) { return "The port must be a number from 1 to 65535." }
        if let bad = services.first(where: { !ServerConfig.isValidServiceName($0) }) {
            return "“\(bad)” isn't a valid service name (letters, digits, - _ . @ : only)."
        }
        let jumpHost = trim(jumpHostField)
        if !jumpHost.isEmpty && !ServerConfig.isSafeArgument(jumpHost) {
            return "The jump host can't start with '-' or contain spaces, quotes or '@'."
        }
        let jumpUser = trim(jumpUserField)
        if !jumpUser.isEmpty && !ServerConfig.isSafeArgument(jumpUser) {
            return "The jump user can't start with '-' or contain spaces, quotes or '@'."
        }
        let jumpPortText = trim(jumpPortField)
        let jumpPort = jumpPortText.isEmpty ? 22 : (Int(jumpPortText) ?? -1)
        if !(1...65535).contains(jumpPort) { return "The jump port must be a number from 1 to 65535." }
        switch selectedAuth {
        case .system:
            break
        case .key:
            let key = pickedKey ?? ServerSecrets.get(id, .privateKey)
            guard let key else { return "Choose a private key file." }
            let typed = passphraseField.stringValue
            let pass = !typed.isEmpty ? typed : (pickedKey == nil ? ServerSecrets.get(id, .passphrase) : nil)
            do {
                try BuiltInSSHSession.validate(privateKey: key, passphrase: pass)
            } catch {
                return error.localizedDescription
            }
        case .password:
            if passwordField.stringValue.isEmpty && !ServerSecrets.has(id, .password) { return "Enter the password." }
        }
        return nil
    }

    func save() -> ServerEditor.Result {
        let host = trim(hostField), portText = trim(portField)
        var name = trim(nameField)
        if name.isEmpty { name = host }
        var cfg = existing ?? ServerConfig(id: id, name: name, host: host, user: trim(userField))
        cfg.name = name
        cfg.host = host
        cfg.user = trim(userField)
        cfg.port = portText.isEmpty ? 22 : (Int(portText) ?? 22)
        cfg.services = services
        cfg.jumpHost = trim(jumpHostField)
        cfg.jumpUser = trim(jumpUserField)
        cfg.jumpPort = trim(jumpPortField).isEmpty ? 22 : (Int(trim(jumpPortField)) ?? 22)
        cfg.useAgent = agentCheck.state == .on
        cfg.auth = selectedAuth
        var changed = false
        switch selectedAuth {
        case .system:
            let ident = trim(identityField)
            cfg.identityFile = ident.isEmpty ? nil : ident
            ServerSecrets.deleteAll(id)
        case .key:
            cfg.identityFile = nil
            if let k = pickedKey { ServerSecrets.set(k, id, .privateKey); changed = true }
            if !passphraseField.stringValue.isEmpty {
                ServerSecrets.set(passphraseField.stringValue, id, .passphrase); changed = true
            } else if pickedKey != nil {
                ServerSecrets.set(nil, id, .passphrase)      // new key without passphrase
            }
            ServerSecrets.set(nil, id, .password)
        case .password:
            cfg.identityFile = nil
            if !passwordField.stringValue.isEmpty {
                ServerSecrets.set(passwordField.stringValue, id, .password); changed = true
            }
            ServerSecrets.set(nil, id, .privateKey)
            ServerSecrets.set(nil, id, .passphrase)
        }
        return ServerEditor.Result(config: cfg, secretsChanged: changed)
    }
}

#if !APPSTORE
/// Reads ~/.ssh/config (following Include lines) for the importer. Direct edition only: the
/// sandboxed App Store edition can't read ~/.ssh.
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
