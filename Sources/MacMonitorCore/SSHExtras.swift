import Foundation

/// OpenSSH private-key header. The public key type is visible even when the private key is encrypted.
public enum OpenSSHKeyInfo {
    public enum Kind: String, Equatable, Sendable {
        case ed25519 = "ssh-ed25519"
        case rsa = "ssh-rsa"
        case ecdsaP256 = "ecdsa-sha2-nistp256"
        case ecdsaP384 = "ecdsa-sha2-nistp384"
        case ecdsaP521 = "ecdsa-sha2-nistp521"
    }

    public struct Header: Equatable, Sendable {
        public var kind: Kind
        public var encrypted: Bool
        /// Unencrypted ECDSA scalar, padded to the curve size. Nil for encrypted or non-ECDSA keys.
        public var scalar: Data?
    }

    public static func inspect(_ pem: String) -> Header? {
        guard let body = decode(pem) else { return nil }
        return parse(body)
    }

    /// `user@host:port` for `ssh -J`, or nil when the host is empty or unsafe.
    public static func proxyJump(user: String, host: String, port: Int) -> String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard ServerConfig.isSafeArgument(host), !host.isEmpty else { return nil }
        let user = user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty && !ServerConfig.isSafeArgument(user) { return nil }
        var spec = user.isEmpty ? host : "\(user)@\(host)"
        if port != 22 {
            guard (1...65535).contains(port) else { return nil }
            spec += ":\(port)"
        }
        return spec
    }

    /// The App Sandbox cannot see `SSH_AUTH_SOCK`. The direct edition can.
    public static func agentIsUsable(socketPath: String?, sandboxed: Bool) -> Bool {
        guard !sandboxed, let socketPath, socketPath.hasPrefix("/"), !socketPath.contains("\n") else { return false }
        return true
    }

    public static func agentFrame(type: UInt8, payload: Data = Data()) -> Data {
        var body = Data([type])
        body.append(payload)
        var out = Data()
        out.append(uint32(UInt32(body.count)))
        out.append(body)
        return out
    }

    public static func agentIdentities(response: Data) -> [Data] {
        guard response.count >= 5, response[0] == 12 else { return [] }
        var index = 1
        guard let count = readUInt32(response, &index) else { return [] }
        var blobs: [Data] = []
        for _ in 0..<count {
            guard let blob = readString(response, &index), readString(response, &index) != nil else { break }
            blobs.append(blob)
        }
        return blobs
    }

    /// Inner signature bytes from an agent sign response, after the algorithm string.
    public static func agentSignatureBytes(response: Data) -> Data? {
        guard response.count >= 5, response[0] == 14 else { return nil }
        var index = 1
        guard let wrapped = readString(response, &index) else { return nil }
        var inner = 0
        guard readString(wrapped, &inner) != nil, let sig = readString(wrapped, &inner) else { return nil }
        return sig
    }

    private static func decode(_ pem: String) -> Data? {
        let lines = pem.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard lines.first?.contains("BEGIN OPENSSH PRIVATE KEY") == true,
              lines.last?.contains("END OPENSSH PRIVATE KEY") == true else { return nil }
        let b64 = lines.dropFirst().dropLast().joined()
        return Data(base64Encoded: b64)
    }

    private static func parse(_ data: Data) -> Header? {
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic) else { return nil }
        var index = magic.count
        guard let cipherData = readString(data, &index),
              let cipher = String(data: cipherData, encoding: .utf8),
              readString(data, &index) != nil,
              readString(data, &index) != nil,
              let nkeys = readUInt32(data, &index), nkeys == 1,
              let publicKey = readString(data, &index) else { return nil }
        var pubIndex = 0
        guard let typeData = readString(publicKey, &pubIndex),
              let type = String(data: typeData, encoding: .utf8),
              let kind = Kind(rawValue: type) else { return nil }
        let encrypted = cipher != "none"
        var scalar: Data?
        if !encrypted, kind == .ecdsaP256 || kind == .ecdsaP384 || kind == .ecdsaP521,
           let secret = readString(data, &index) {
            scalar = scalarFromPrivate(secret, kind: kind)
        }
        return Header(kind: kind, encrypted: encrypted, scalar: scalar)
    }

    private static func scalarFromPrivate(_ secret: Data, kind: Kind) -> Data? {
        var index = 8 // two check uint32s
        guard readString(secret, &index) != nil,
              readString(secret, &index) != nil,
              readString(secret, &index) != nil,
              let mpint = readString(secret, &index) else { return nil }
        let size: Int
        switch kind {
        case .ecdsaP256: size = 32
        case .ecdsaP384: size = 48
        case .ecdsaP521: size = 66
        default: return nil
        }
        var bytes = mpint
        if bytes.first == 0 { bytes.removeFirst() }
        if bytes.count > size { return nil }
        return Data(repeating: 0, count: size - bytes.count) + bytes
    }

    public static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value & 0xff)])
    }

    static func readUInt32(_ data: Data, _ index: inout Int) -> UInt32? {
        guard index + 4 <= data.count else { return nil }
        let v = UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16 | UInt32(data[index + 2]) << 8 | UInt32(data[index + 3])
        index += 4
        return v
    }

    public static func readString(_ data: Data, _ index: inout Int) -> Data? {
        guard let n = readUInt32(data, &index), index + Int(n) <= data.count else { return nil }
        let slice = data.subdata(in: index..<(index + Int(n)))
        index += Int(n)
        return slice
    }
}
