import Foundation
import MacMonitorCore
import MacMonitorSSH

/// One SSH session running the remote monitoring loop. Callbacks may arrive on any thread.
protocol RemoteTransport: AnyObject {
    /// `onExit` is called once with a human-readable reason when the session ends on its own
    /// (never after `stop()`).
    func start(onStdout: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (String) -> Void)
    func stop()
}

enum TransportFactory {
    /// Builds the transport for a server, or returns an error message to show instead.
    static func make(for config: ServerConfig) -> Result<RemoteTransport, TransportError> {
        switch config.auth {
        case .system:
            #if APPSTORE
            return .failure(TransportError(message:
                "The App Store edition can't use the system ssh. Edit the server and choose a key file or password."))
            #else
            return .success(ProcessTransport(arguments: RemoteScript.sshArguments(for: config)))
            #endif
        case .key, .password:
            return .success(BuiltInTransport(config: config))
        }
    }
}

struct TransportError: Error { let message: String }

// MARK: - /usr/bin/ssh (direct edition)

#if !APPSTORE
final class ProcessTransport: RemoteTransport, @unchecked Sendable {
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private let tail = StderrTail()

    init(arguments: [String]) { self.arguments = arguments }

    func start(onStdout: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let tail = self.tail

        // readabilityHandler runs on a private background queue. At EOF it is called with
        // empty data repeatedly unless cleared, so always clear it on empty reads.
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            onStdout(data)
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            tail.append(data)
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            // Give the stderr handler a moment to drain the final message.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                var msg = tail.lastMessage()
                if msg.isEmpty { msg = code == 255 ? "Connection failed" : "Connection closed (exit \(code))" }
                onExit(msg)
            }
        }
        do {
            try p.run()
            lock.lock(); process = p; lock.unlock()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let msg = "Couldn't start ssh: \(error.localizedDescription)"
            DispatchQueue.global().async { onExit(msg) }
        }
    }

    func stop() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p else { return }
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }   // SIGTERM: ssh closes the session
    }
}
#endif

// MARK: - Built-in client (both editions; the only option inside the App Sandbox)

final class BuiltInTransport: RemoteTransport, @unchecked Sendable {
    private let session: BuiltInSSHSession
    private let command: String
    private let tail = StderrTail()

    init(config: ServerConfig) {
        let id = config.id
        command = RemoteScript.remoteCommand(services: config.services)
        let creds = BuiltInSSHSession.Credentials(
            username: config.user.isEmpty ? NSUserName() : config.user,
            privateKey: config.auth == .key ? ServerSecrets.get(id, .privateKey) : nil,
            passphrase: config.auth == .key ? ServerSecrets.get(id, .passphrase) : nil,
            password: config.auth == .password ? ServerSecrets.get(id, .password) : nil)
        session = BuiltInSSHSession(host: config.host, port: config.port, credentials: creds,
                                    knownHostKey: KnownHostKeys.get(id),
                                    onNewHostKey: { key in
                                        DispatchQueue.main.async { KnownHostKeys.set(key, id) }
                                    })
    }

    func start(onStdout: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (String) -> Void) {
        let tail = self.tail
        session.start(command: command, onStdout: onStdout,
                      onStderr: { tail.append($0) },
                      onExit: { reason in
                          // A remote error message (e.g. "sh: not found") beats a generic exit reason.
                          let remote = tail.lastMessage()
                          onExit(reason.hasPrefix("Remote command exited") && !remote.isEmpty ? remote : reason)
                      })
    }

    func stop() { session.stop() }
}

/// Keeps the last ~2 KB of stderr (written from a background queue).
final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > 2048 { data = Data(data.suffix(2048)) }
    }

    /// Last meaningful stderr line, shortened for display.
    func lastMessage() -> String {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        guard var line = lines.last else { return "" }
        if line.hasPrefix("ssh: ") { line.removeFirst(5) }
        if line.count > 90 { line = String(line.prefix(89)) + "…" }
        return line
    }
}
