import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// In-process SSH client (Citadel on SwiftNIO SSH). Unlike /usr/bin/ssh it works inside the
/// App Sandbox, so the Mac App Store edition can monitor servers too.
///
/// - Auth: OpenSSH-format ed25519 or RSA private keys (optionally passphrase-protected), or a password.
/// - Host keys: trust on first use. The first key seen is reported through `onNewHostKey` so the
///   caller can store it; later connections must present the same key or are refused.
public final class BuiltInSSHSession: @unchecked Sendable {
    public struct Credentials: Sendable {
        public var username: String
        public var privateKey: String?
        public var passphrase: String?
        public var password: String?

        public init(username: String, privateKey: String? = nil, passphrase: String? = nil, password: String? = nil) {
            self.username = username; self.privateKey = privateKey
            self.passphrase = passphrase; self.password = password
        }
    }

    public enum SessionError: LocalizedError {
        case missingCredentials
        case unsupportedKey(String)
        case hostKeyChanged(expected: String, got: String)
        case commandEnded(Int?)

        public var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "No key or password saved for this server. Edit the server to add one."
            case .unsupportedKey(let why):
                return why
            case .hostKeyChanged(_, let got):
                return "Host key changed (now \(BuiltInSSHSession.fingerprint(of: got))). Refusing to connect. "
                    + "If the server was reinstalled, choose “Trust New Host Key”."
            case .commandEnded(let code):
                return code.map { "Remote command exited (\($0))" } ?? "Connection closed"
            }
        }
    }

    private let host: String
    private let port: Int
    private let credentials: Credentials
    private let knownHostKey: String?
    private let onNewHostKey: @Sendable (String) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var client: SSHClient?
    private var stopped = false

    public init(host: String, port: Int, credentials: Credentials, knownHostKey: String?,
                onNewHostKey: @escaping @Sendable (String) -> Void) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.knownHostKey = knownHostKey
        self.onNewHostKey = onNewHostKey
    }

    /// Connects, runs `command`, and streams its output. `onExit` is called exactly once with a
    /// human-readable reason (never for a `stop()` the caller asked for).
    public func start(command: String,
                      onStdout: @escaping @Sendable (Data) -> Void,
                      onStderr: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (String) -> Void) {
        let t = Task { [self] in
            var reason = "Connection closed"
            do {
                let auth = try Self.authenticationMethod(for: credentials)
                let validator = TOFUHostKeyValidator(expected: knownHostKey, onNew: onNewHostKey)
                let client = try await SSHClient.connect(host: host, port: port, authenticationMethod: auth,
                                                         hostKeyValidator: .custom(validator), reconnect: .never,
                                                         connectTimeout: .seconds(10))
                setClient(client)
                if isStopped { try? await client.close(); return }
                let stream = try await client.executeCommandStream(command)
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buf): onStdout(Data(buf.readableBytesView))
                    case .stderr(let buf): onStderr(Data(buf.readableBytesView))
                    }
                }
                reason = SessionError.commandEnded(nil).errorDescription ?? reason
            } catch let e as SSHClient.CommandFailed {
                reason = SessionError.commandEnded(e.exitCode).errorDescription ?? reason
            } catch let e as TOFUHostKeyValidator.Mismatch {
                reason = SessionError.hostKeyChanged(expected: e.expected, got: e.got).errorDescription ?? reason
            } catch {
                reason = Self.describe(error)
            }
            if let c = takeClient() { try? await c.close() }
            if !isStopped { onExit(reason) }
        }
        lock.lock(); task = t; lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let t = task
        let c = client
        client = nil
        lock.unlock()
        t?.cancel()
        if let c { Task { try? await c.close() } }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func setClient(_ c: SSHClient) { lock.lock(); client = c; lock.unlock() }
    private func takeClient() -> SSHClient? { lock.lock(); defer { lock.unlock() }; let c = client; client = nil; return c }

    // MARK: Auth

    static func authenticationMethod(for c: Credentials) throws -> SSHAuthenticationMethod {
        if let key = c.privateKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return try keyMethod(username: c.username, key: key, passphrase: c.passphrase)
        }
        if let pw = c.password, !pw.isEmpty {
            return .passwordBased(username: c.username, password: pw)
        }
        throw SessionError.missingCredentials
    }

    /// Validates a private key without connecting (used when the user picks a key file).
    public static func validate(privateKey: String, passphrase: String?) throws {
        _ = try keyMethod(username: "check", key: privateKey.trimmingCharacters(in: .whitespacesAndNewlines),
                          passphrase: passphrase)
    }

    private static func keyMethod(username: String, key: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        guard key.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") else {
            if key.hasPrefix("-----BEGIN") {
                throw SessionError.unsupportedKey(
                    "This key is in PEM format. Convert it with: ssh-keygen -p -f <key> (keeps the key, rewrites it in OpenSSH format).")
            }
            throw SessionError.unsupportedKey("That file isn't an OpenSSH private key.")
        }
        let decryption = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let type = try? SSHKeyDetection.detectPrivateKeyType(from: key)
        do {
            if type == .ed25519 {
                return .ed25519(username: username,
                                privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: decryption))
            } else if type == .rsa {
                return .rsa(username: username,
                            privateKey: try Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: decryption))
            } else if let other = type {
                throw SessionError.unsupportedKey(
                    "\(other) keys aren't supported by the built-in client yet. Use an ed25519 or RSA key.")
            }
            // Detection failed: try both formats before giving up.
            if let k = try? Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: decryption) {
                return .ed25519(username: username, privateKey: k)
            }
            return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: decryption))
        } catch let e as SessionError {
            throw e
        } catch {
            throw SessionError.unsupportedKey(passphrase?.isEmpty ?? true
                ? "Couldn't read the key. If it has a passphrase, enter it."
                : "Couldn't decrypt the key. Check the passphrase.")
        }
    }

    // MARK: Helpers

    /// "SHA256:…" like `ssh-keygen -lf`.
    public static func fingerprint(of openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return openSSHKey }
        let digest = SHA256.hash(data: blob)
        var b64 = Data(digest).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if let e = error as? SSHClientError {
            switch e {
            case .allAuthenticationOptionsFailed: return "Permission denied (authentication failed)"
            case .unsupportedPasswordAuthentication: return "The server doesn't accept password login"
            case .unsupportedPrivateKeyAuthentication: return "The server doesn't accept this key type"
            default: return "SSH error: \(e)"
            }
        }
        let text = String(describing: error)
        if text.contains("connectTimeout") || text.contains("timeout") { return "Connection timed out" }
        if text.contains("connectionRefused") || text.contains("Connection refused") { return "Connection refused" }
        if text.contains("NXDOMAIN") || text.contains("resolve") { return "Could not resolve host name" }
        return text.count > 120 ? String(text.prefix(119)) + "…" : text
    }
}

/// Trust-on-first-use host key check.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Mismatch: Error { let expected: String; let got: String }

    private let expected: String?
    private let onNew: @Sendable (String) -> Void

    init(expected: String?, onNew: @escaping @Sendable (String) -> Void) {
        self.expected = expected
        self.onNew = onNew
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        guard let expected, !expected.isEmpty else {
            onNew(presented)
            validationCompletePromise.succeed(())
            return
        }
        if Self.normalized(expected) == Self.normalized(presented) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(Mismatch(expected: expected, got: presented))
        }
    }

    /// "type base64 [comment]" -> "type base64"
    static func normalized(_ key: String) -> String {
        key.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
