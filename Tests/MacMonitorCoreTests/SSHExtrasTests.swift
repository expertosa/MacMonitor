import XCTest
@testable import MacMonitorCore

final class SSHExtrasTests: XCTestCase {
    func testProxyJumpAndAgentPolicy() {
        XCTAssertEqual(OpenSSHKeyInfo.proxyJump(user: "jump", host: "bastion.example", port: 22), "jump@bastion.example")
        XCTAssertEqual(OpenSSHKeyInfo.proxyJump(user: "", host: "bastion", port: 2222), "bastion:2222")
        XCTAssertNil(OpenSSHKeyInfo.proxyJump(user: "a b", host: "bastion", port: 22))
        XCTAssertNil(OpenSSHKeyInfo.proxyJump(user: "", host: "-oProxyCommand", port: 22))
        XCTAssertFalse(OpenSSHKeyInfo.agentIsUsable(socketPath: "/tmp/agent.sock", sandboxed: true))
        XCTAssertTrue(OpenSSHKeyInfo.agentIsUsable(socketPath: "/tmp/agent.sock", sandboxed: false))
        XCTAssertFalse(OpenSSHKeyInfo.agentIsUsable(socketPath: "relative", sandboxed: false))
    }

    func testAgentFraming() {
        let frame = OpenSSHKeyInfo.agentFrame(type: 11)
        XCTAssertEqual([UInt8](frame), [0, 0, 0, 1, 11])
        var body = Data()
        body.append(OpenSSHKeyInfo.uint32(1))
        let blob = Data("key".utf8)
        body.append(OpenSSHKeyInfo.uint32(UInt32(blob.count)))
        body.append(blob)
        let comment = Data("me".utf8)
        body.append(OpenSSHKeyInfo.uint32(UInt32(comment.count)))
        body.append(comment)
        var response = Data([12])
        response.append(body)
        XCTAssertEqual(OpenSSHKeyInfo.agentIdentities(response: response), [blob])

        var sig = Data()
        let alg = Data("ssh-ed25519".utf8)
        let raw = Data(repeating: 7, count: 64)
        sig.append(OpenSSHKeyInfo.uint32(UInt32(alg.count)))
        sig.append(alg)
        sig.append(OpenSSHKeyInfo.uint32(UInt32(raw.count)))
        sig.append(raw)
        var wrapped = Data([14])
        wrapped.append(OpenSSHKeyInfo.uint32(UInt32(sig.count)))
        wrapped.append(sig)
        XCTAssertEqual(OpenSSHKeyInfo.agentSignatureBytes(response: wrapped), raw)
    }

    func testUnencryptedECDSAHeader() {
        let pem = Self.sampleKey()
        let header = OpenSSHKeyInfo.inspect(pem)
        XCTAssertEqual(header?.kind, .ecdsaP256)
        XCTAssertEqual(header?.encrypted, false)
        XCTAssertEqual(header?.scalar?.count, 32)
        XCTAssertEqual(header?.scalar?.last, 9)
        XCTAssertNil(OpenSSHKeyInfo.inspect("-----BEGIN RSA PRIVATE KEY-----\nAA==\n-----END RSA PRIVATE KEY-----"))
    }

    private static func sampleKey() -> String {
        func str(_ s: String) -> Data { OpenSSHKeyInfo.uint32(UInt32(s.utf8.count)) + Data(s.utf8) }
        func blob(_ d: Data) -> Data { OpenSSHKeyInfo.uint32(UInt32(d.count)) + d }
        var pub = str("ecdsa-sha2-nistp256") + str("nistp256") + blob(Data([0x04, 1, 2]))
        var secret = OpenSSHKeyInfo.uint32(1) + OpenSSHKeyInfo.uint32(1)
        secret += str("ecdsa-sha2-nistp256") + str("nistp256") + blob(Data([0x04, 1, 2]))
        secret += blob(Data([0x00, 9])) // mpint with a leading zero
        secret += str("")
        var body = Data("openssh-key-v1\0".utf8)
        body += str("none") + str("none") + blob(Data())
        body += OpenSSHKeyInfo.uint32(1)
        body += blob(pub)
        body += blob(secret)
        let b64 = body.base64EncodedString()
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
