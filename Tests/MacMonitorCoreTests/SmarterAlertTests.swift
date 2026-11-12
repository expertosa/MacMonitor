import XCTest
@testable import MacMonitorCore

final class SmarterAlertTests: XCTestCase {
    private func settings() -> AlertSettings {
        var s = AlertSettings()
        s.enabled = true
        s.serverCPUMinutes = 0
        s.docker = true
        s.certificates = true
        s.sslWarnDays = 14
        return s
    }

    private func server(cpu: Double = 0, cpuLimit: Double? = nil, diskLimit: Double? = nil) -> AlertInput.Server {
        AlertInput.Server(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                           name: "web", offline: false, online: true, cpu: cpu,
                           disks: [RemoteDisk(mount: "/", device: "sda", total: 100, used: 50, free: 50)],
                           cpuPercent: cpuLimit, diskPercent: diskLimit)
    }

    func testPerServerCPUThresholdOverridesGlobal() {
        let engine = AlertEngine()
        var input = AlertInput()
        input.servers = [server(cpu: 0.5, cpuLimit: 40)]
        let events = engine.evaluate(input, settings: settings(), now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(events.map(\.title), ["High CPU on web"])
        var loose = AlertSettings()
        loose.enabled = true
        loose.serverCPUMinutes = 0
        loose.serverCPUPercent = 95
        input.servers = [server(cpu: 0.5, cpuLimit: 90)]
        XCTAssertTrue(AlertEngine().evaluate(input, settings: loose).isEmpty)
    }

    func testDockerStopFiresOnceOnTransition() {
        let engine = AlertEngine()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        func input(_ containers: [DockerContainer]) -> AlertInput {
            var input = AlertInput()
            input.servers = [AlertInput.Server(id: id, name: "web", offline: false, online: true,
                                                containers: containers, extrasFresh: true)]
            return input
        }
        let running = [DockerContainer(name: "api", state: "running"), DockerContainer(name: "db", state: "running")]
        XCTAssertTrue(engine.evaluate(input(running), settings: settings()).isEmpty)
        let stopped = [DockerContainer(name: "api", state: "exited"), DockerContainer(name: "db", state: "running")]
        let events = engine.evaluate(input(stopped), settings: settings())
        XCTAssertEqual(events.map(\.title), ["Container api stopped on web"])
        XCTAssertTrue(engine.evaluate(input(stopped), settings: settings()).isEmpty)
    }

    func testCertificateExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let soon = CertificateStatus(host: "example.com", notAfter: now.addingTimeInterval(3 * 86_400), daysRemaining: 3)
        let later = CertificateStatus(host: "ok.example.com", notAfter: now.addingTimeInterval(40 * 86_400), daysRemaining: 40)
        var input = AlertInput()
        input.servers = [AlertInput.Server(id: UUID(), name: "web", offline: false, online: true,
                                            certificates: [soon, later])]
        let titles = AlertEngine().evaluate(input, settings: settings(), now: now).map(\.title)
        XCTAssertEqual(titles, ["Certificate for example.com expires soon"])
    }

    func testOpenSSLDateAndDockerLine() {
        let date = RemoteParse.notAfterDate("notAfter=Nov 12 23:59:59 2026 GMT")
        XCTAssertNotNil(date)
        let cert = RemoteParse.certificate(from: "example.com notAfter=Nov 12 23:59:59 2026 GMT",
                                            now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(cert?.host, "example.com")
        XCTAssertNotNil(cert?.daysRemaining)
        XCTAssertNil(RemoteParse.container(from: "bad name|running"))
        XCTAssertEqual(RemoteParse.container(from: "api_1|running")?.isRunning, true)
        let script = RemoteScript.script(services: [], certHosts: ["example.com", "bad;rm", "$(id)"])
        XCTAssertTrue(script.contains("example.com"))
        XCTAssertFalse(script.contains("bad;rm"))
        XCTAssertFalse(script.contains("$(id)"))
        XCTAssertFalse(script.contains("'"))
        XCTAssertFalse(script.contains("\\"))
        XCTAssertFalse(RemoteScript.script(certHosts: []).contains("openssl"))
    }

    func testDeliveryBuildsRequestsAndRejectsSecrets() throws {
        var settings = AlertSettings()
        settings.enabled = true
        settings.telegram = true
        settings.slack = true
        settings.webhook = true
        let secrets = AlertChannels.Secrets(
            telegramToken: "123456789:AA" + String(repeating: "b", count: 30),
            telegramChat: "-100123",
            slackWebhook: "https://hooks.slack.com/services/T00/B00/xxx",
            webhookURL: "https://alerts.example.com/hook"
        )
        let event = AlertEvent(id: "cpu", title: "High CPU", body: "now")
        let requests = AlertChannels.requests(for: [event], settings: settings, secrets: secrets)
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[0].url.absoluteString.hasPrefix("https://api.telegram.org/bot"))
        let telegram = try JSONSerialization.jsonObject(with: requests[0].body) as? [String: String]
        XCTAssertEqual(telegram?["chat_id"], "-100123")
        XCTAssertNil(AlertChannels.telegram(token: "nope", chat: "1", text: "x"))
        XCTAssertNil(AlertChannels.slack(webhook: "http://hooks.slack.com/services/x", text: "x"))
        XCTAssertNil(AlertChannels.webhook(url: "http://example.com/hook", event: event))
        var off = settings
        off.enabled = false
        XCTAssertTrue(AlertChannels.requests(for: [event], settings: off, secrets: secrets).isEmpty)
    }

    func testOldSettingsStillDecode() throws {
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.docker)
        XCTAssertEqual(s.sslWarnDays, 14)
        XCTAssertFalse(s.telegram)
        let server = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"host":"h"}"#.utf8))
        XCTAssertTrue(server.certHosts.isEmpty)
        XCTAssertNil(server.cpuPercent)
    }
}
