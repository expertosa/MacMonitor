import Foundation
import MacMonitorCore
import Crypto
import NIOCore
import NIOSSH
import Citadel

/// ssh-agent over `SSH_AUTH_SOCK`. Used by the built-in client only when the sandbox allows the socket.
enum SSHAgentAuth {
    static func method(username: String, socket: String) throws -> SSHAuthenticationMethod {
        let identities = try Client.identities(socket: socket)
        guard let blob = identities.first(where: { typeOf($0) == "ssh-ed25519" }) else {
            throw BuiltInSSHSession.SessionError.unsupportedKey(
                "ssh-agent has no ed25519 identity. The built-in client asks the agent to sign with an ed25519 key.")
        }
        let key = AgentKey(blob: blob, socket: socket)
        return .custom(Delegate(username: username, key: key))
    }

    private final class Delegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
        let username: String
        let key: AgentKey
        private var offered = false
        init(username: String, key: AgentKey) {
            self.username = username
            self.key = key
        }
        func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
            guard !offered, availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
                return
            }
            offered = true
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(custom: key))))
            nextChallengePromise.succeed(offer)
        }
    }

    private struct AgentKey: NIOSSHPrivateKeyProtocol {
        static var keyPrefix: String { "ssh-ed25519" }
        let blob: Data
        let socket: String
        var publicKey: NIOSSHPublicKeyProtocol { AgentPublic(blob: blob) }
        func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            let signed = try Client.sign(socket: socket, key: blob, data: Data(data))
            return AgentSignature(bytes: signed)
        }
    }

    private struct AgentPublic: NIOSSHPublicKeyProtocol {
        static var publicKeyPrefix: String { AgentKey.keyPrefix }
        let blob: Data
        var rawRepresentation: Data { material }
        var material: Data {
            var index = 0
            _ = OpenSSHKeyInfo.readString(blob, &index)
            return blob.subdata(in: index..<blob.count)
        }
        func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }
        func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeBytes(material)
            return material.count
        }
        static func read(from buffer: inout ByteBuffer) throws -> AgentPublic { throw AgentError.unsupported }
    }

    private struct AgentSignature: NIOSSHSignatureProtocol {
        static var signaturePrefix: String { AgentKey.keyPrefix }
        let bytes: Data
        var rawRepresentation: Data { bytes }
        func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeInteger(UInt32(bytes.count), endianness: .big)
            buffer.writeBytes(bytes)
            return 4 + bytes.count
        }
        static func read(from buffer: inout ByteBuffer) throws -> AgentSignature { throw AgentError.unsupported }
    }

    private enum AgentError: Error { case unsupported, protocolError, socket }

    private static func typeOf(_ blob: Data) -> String? {
        var index = 0
        guard let data = OpenSSHKeyInfo.readString(blob, &index) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum Client {
        static func identities(socket: String) throws -> [Data] {
            let response = try exchange(socket: socket, request: OpenSSHKeyInfo.agentFrame(type: 11))
            return OpenSSHKeyInfo.agentIdentities(response: response)
        }

        static func sign(socket: String, key: Data, data: Data) throws -> Data {
            var payload = Data()
            payload.append(OpenSSHKeyInfo.uint32(UInt32(key.count)))
            payload.append(key)
            payload.append(OpenSSHKeyInfo.uint32(UInt32(data.count)))
            payload.append(data)
            payload.append(OpenSSHKeyInfo.uint32(0))
            let response = try exchange(socket: socket, request: OpenSSHKeyInfo.agentFrame(type: 13, payload: payload))
            guard let bytes = OpenSSHKeyInfo.agentSignatureBytes(response: response) else { throw AgentError.protocolError }
            return bytes
        }

        private static func exchange(socket path: String, request: Data) throws -> Data {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw AgentError.socket }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bound = path.withCString { cString -> Bool in
                withUnsafeMutableBytes(of: &address.sun_path) { raw in
                    let n = min(raw.count - 1, strlen(cString))
                    raw.copyBytes(from: UnsafeRawBufferPointer(start: cString, count: n))
                    raw[n] = 0
                }
                return true
            }
            guard bound else { throw AgentError.socket }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw AgentError.socket }
            try request.withUnsafeBytes { raw in
                var sent = 0
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                while sent < request.count {
                    let n = write(fd, base.advanced(by: sent), request.count - sent)
                    if n <= 0 { throw AgentError.socket }
                    sent += n
                }
            }
            var header = [UInt8](repeating: 0, count: 4)
            var got = 0
            while got < 4 {
                let n = read(fd, &header[got], 4 - got)
                if n <= 0 { throw AgentError.socket }
                got += n
            }
            let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
            guard (1...1_000_000).contains(length) else { throw AgentError.protocolError }
            var body = [UInt8](repeating: 0, count: length)
            got = 0
            while got < length {
                let n = read(fd, &body[got], length - got)
                if n <= 0 { throw AgentError.socket }
                got += n
            }
            return Data(body)
        }
    }
}
