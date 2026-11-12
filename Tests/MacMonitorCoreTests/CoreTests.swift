import XCTest
@testable import MacMonitorCore

final class SSHConfigTests: XCTestCase {
    func testParsesConcreteHosts() {
        let text = """
        # comment
        Host *
            ServerAliveInterval 30
        Host web-01 web-02
            HostName 10.0.0.1
            User deploy
            Port 2222
        Host db
          HostName=db.internal
          User = postgres
          IdentityFile "~/.ssh/db key"
          Port 22 # trailing comment
        Host *.example.com !bastion
            User nobody
        Include extra.conf
        Match host foo
            User ignored
        Include ignored-inside-match.conf
        """
        let entries = SSHConfigParser.parse(text) { arg in
            arg == "extra.conf" ? ["Host extra\n  User x\nHost db\n  User shadowed"] : []
        }
        XCTAssertEqual(entries.map(\.alias), ["web-01", "web-02", "db", "extra"])
        XCTAssertEqual(entries[0].hostName, "10.0.0.1")
        XCTAssertEqual(entries[1].user, "deploy")
        XCTAssertEqual(entries[1].port, 2222)
        XCTAssertEqual(entries[2].hostName, "db.internal")
        XCTAssertEqual(entries[2].user, "postgres")
        XCTAssertEqual(entries[2].identityFile, "~/.ssh/db key")
        XCTAssertEqual(entries[2].port, 22)
        let cfg = entries[0].serverConfig()
        XCTAssertEqual(cfg.host, "web-01")
        XCTAssertEqual(cfg.port, 2222)
        XCTAssertEqual(cfg.user, "deploy")
    }

    func testFirstValueWins() {
        let e = SSHConfigParser.parse("Host a\n User one\n User two\n")
        XCTAssertEqual(e.first?.user, "one")
    }
}

final class VersionTests: XCTestCase {
    func testCompare() {
        XCTAssertLessThan(AppVersion("1.2")!, AppVersion("v1.10")!)
        XCTAssertEqual(AppVersion("1.2.0")!, AppVersion("1.2")!)
        XCTAssertLessThan(AppVersion("1.9.9")!, AppVersion("2")!)
        XCTAssertEqual(AppVersion("v2.0.0-beta.1")?.description, "2.0.0")
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion(""))
    }
}

final class FormattingTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(Fmt.pct(0.256), "26%")
        XCTAssertEqual(Fmt.rate(1_500), "1.5 KB/s")
        XCTAssertEqual(Fmt.shortRate(2_500_000), "2.5M")
        XCTAssertEqual(Fmt.duration(90_061), "1d 1h")
        XCTAssertEqual(Fmt.duration(3_720), "1h 2m")
        XCTAssertEqual(Fmt.duration(59), "59s")
    }
}

final class SharedStoreTests: XCTestCase {
    func testRoundTrip() {
        let p = WidgetPayload(updated: Date(timeIntervalSince1970: 1_700_000_000), hostName: "Mac",
                              servers: [WidgetServer(id: UUID(), name: "s", state: .online, cpu: 0.5,
                                                     warnings: ["reboot required"])])
        XCTAssertEqual(SharedStore.decode(SharedStore.encode(p)!), p)
    }
}

final class AlertEngineTests: XCTestCase {
    private var settings: AlertSettings {
        var s = AlertSettings()
        s.enabled = true
        s.cpuPercent = 90; s.cpuMinutes = 5
        s.diskPercent = 90
        s.serverOfflineMinutes = 2
        return s
    }

    func testDisabledProducesNothing() {
        var input = AlertInput()
        input.cpu = 1
        XCTAssertTrue(AlertEngine().evaluate(input, settings: AlertSettings()).isEmpty)
    }

    func testCPUMustBeSustained() {
        let engine = AlertEngine()
        var input = AlertInput()
        input.cpu = 0.95
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(engine.evaluate(input, settings: settings, now: t0).isEmpty)
        XCTAssertTrue(engine.evaluate(input, settings: settings, now: t0 + 200).isEmpty)
        XCTAssertEqual(engine.evaluate(input, settings: settings, now: t0 + 300).map(\.id), ["cpu"])
        XCTAssertTrue(engine.evaluate(input, settings: settings, now: t0 + 400).isEmpty)   // once
        // Hysteresis: 89% keeps it "firing" (no re-arm), 50% re-arms.
        input.cpu = 0.89
        XCTAssertTrue(engine.evaluate(input, settings: settings, now: t0 + 500).isEmpty)
        input.cpu = 0.5
        _ = engine.evaluate(input, settings: settings, now: t0 + 600)
        input.cpu = 0.95
        XCTAssertTrue(engine.evaluate(input, settings: settings, now: t0 + 700).isEmpty)
        XCTAssertEqual(engine.evaluate(input, settings: settings, now: t0 + 1000).count, 1)
    }

    func testDiskAndBattery() {
        let engine = AlertEngine()
        var input = AlertInput()
        input.volumes = [.init(id: "/", name: "Macintosh HD", usedFraction: 0.95)]
        input.batteryPercent = 10
        input.batteryCharging = true
        let ids = engine.evaluate(input, settings: settings).map(\.id)
        XCTAssertEqual(ids, ["disk:/"])
        input.batteryCharging = false
        XCTAssertEqual(engine.evaluate(input, settings: settings).map(\.id), ["battery"])
    }

    func testServerOfflineAndRecovery() {
        let engine = AlertEngine()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 0)
        var input = AlertInput()
        input.servers = [.init(id: id, name: "web", offline: true, online: false)]
        XCTAssertTrue(engine.evaluate(input, settings: settings, now: t0).isEmpty)
        let fired = engine.evaluate(input, settings: settings, now: t0 + 120)
        XCTAssertEqual(fired.map(\.title), ["web is unreachable"])
        input.servers = [.init(id: id, name: "web", offline: false, online: true)]
        XCTAssertEqual(engine.evaluate(input, settings: settings, now: t0 + 130).map(\.title), ["web is back online"])
    }

    func testServiceDownAndReboot() {
        let engine = AlertEngine()
        let id = UUID()
        var input = AlertInput()
        input.servers = [.init(id: id, name: "web", offline: false, online: true,
                               services: [ServiceState(name: "nginx", state: "failed"),
                                          ServiceState(name: "redis", state: "")],
                               rebootRequired: true)]
        let titles = engine.evaluate(input, settings: settings).map(\.title)
        XCTAssertEqual(titles, ["nginx is failed on web", "web needs a reboot"])
        input.servers[0].services = [ServiceState(name: "nginx", state: "active")]
        XCTAssertEqual(engine.evaluate(input, settings: settings).map(\.title), ["nginx is running again on web"])
    }

    func testRemovedServerIsForgotten() {
        let engine = AlertEngine()
        var input = AlertInput()
        input.servers = [.init(id: UUID(), name: "a", offline: false, online: true, rebootRequired: true)]
        XCTAssertEqual(engine.evaluate(input, settings: settings).count, 1)
        input.servers = []
        XCTAssertTrue(engine.evaluate(input, settings: settings).isEmpty)
    }

    func testSettingsDecodeTolerant() throws {
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"enabled":true,"diskPercent":80}"#.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.diskPercent, 80)
        XCTAssertEqual(s.cpuPercent, 90)
    }
}

final class AppDisplayTests: XCTestCase {
    func testUserFacingName() {
        XCTAssertEqual(AppDisplay.name, "Monitor CTRL")
    }
}
