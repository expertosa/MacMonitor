import Foundation
import MacMonitorCore
import MacMonitorSSH

/// Runs one confirmed command on a server and returns the combined output.
enum OneShotSSH {
    static func run(_ config: ServerConfig, command: String, completion: @escaping @MainActor (String) -> Void) {
        switch config.auth {
        case .system:
            #if APPSTORE
            Task { @MainActor in
                completion("The App Store edition needs a saved key or password for remote actions.")
            }
            #else
            runProcess(config, command: command, completion: completion)
            #endif
        case .key, .password:
            runBuiltIn(config, command: command, completion: completion)
        }
    }

    #if !APPSTORE
    private static func runProcess(_ config: ServerConfig, command: String,
                                   completion: @escaping @MainActor (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = RemoteScript.sshArguments(for: config, remoteCommand: command, connectTimeout: 20)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            var text = ""
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                text = String(decoding: data.prefix(16_000), as: UTF8.self)
                if text.isEmpty { text = "Finished with exit \(process.terminationStatus)." }
            } catch {
                text = "Couldn't start ssh: \(error.localizedDescription)"
            }
            let output = text
            Task { @MainActor in completion(output) }
        }
    }
    #endif

    private static func runBuiltIn(_ config: ServerConfig, command: String,
                                   completion: @escaping @MainActor (String) -> Void) {
        let id = config.id
        let creds = BuiltInSSHSession.Credentials(
            username: config.user.isEmpty ? NSUserName() : config.user,
            privateKey: config.auth == .key ? ServerSecrets.get(id, .privateKey) : nil,
            passphrase: config.auth == .key ? ServerSecrets.get(id, .passphrase) : nil,
            password: config.auth == .password ? ServerSecrets.get(id, .password) : nil)
        let session = BuiltInSSHSession(host: config.host, port: config.port, credentials: creds,
                                         knownHostKey: KnownHostKeys.get(id),
                                         onNewHostKey: { key in
                                             DispatchQueue.main.async { KnownHostKeys.set(key, id) }
                                         })
        let box = OutputBox()
        session.start(command: command, onStdout: { box.append($0) }, onStderr: { box.append($0) },
                      onExit: { reason in
                          var text = box.text
                          if text.isEmpty { text = reason }
                          Task { @MainActor in completion(text) }
                      })
        // Keep the session alive until the command ends.
        box.session = session
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var session: BuiltInSSHSession?
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < 16_000 else { return }
        data.append(chunk.prefix(16_000 - data.count))
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
