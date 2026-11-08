import XCTest
@testable import MacMonitorCore

final class RemoteParseTests: XCTestCase {

    // MARK: Script safety

    func testScriptIsSingleLineWithoutQuotesOrBackslashes() {
        let s = RemoteScript.script(services: ["nginx", "postgresql@14-main"])
        XCTAssertFalse(s.contains("'"))
        XCTAssertFalse(s.contains("\\"))
        XCTAssertFalse(s.contains("\n"))
        XCTAssertTrue(s.contains("SVC=\"nginx postgresql@14-main\";"))
    }

    func testInvalidServiceNamesAreNotInjected() {
        let s = RemoteScript.script(services: ["ok", "bad;rm -rf /", "$(id)", "-x"])
        XCTAssertTrue(s.contains("SVC=\"ok\";"))
        XCTAssertFalse(s.contains("rm -rf"))
        XCTAssertFalse(s.contains("$(id)"))
    }

    func testSSHArguments() {
        let cfg = ServerConfig(name: "web", host: "web-01", user: "admin", port: 2222, identityFile: "/k")
        let args = RemoteScript.sshArguments(for: cfg)
        XCTAssertEqual(args[args.count - 2], "admin@web-01")
        XCTAssertTrue(args.contains("2222"))
        XCTAssertEqual(args[args.firstIndex(of: "-i")! + 1], "/k")
        XCTAssertTrue(args.last!.hasPrefix("sh -c '"))
    }

    func testServerConfigDecodesOldFormat() throws {
        let json = #"[{"host":"h1"},{"id":"6A1C6B1E-7A5B-4C55-9A9C-4C0E1C8C2F10","name":"n","host":"h2","user":"u","port":2200,"services":["nginx","bad name"]}]"#
        let list = try JSONDecoder().decode([ServerConfig].self, from: Data(json.utf8))
        XCTAssertEqual(list[0].name, "h1")
        XCTAssertEqual(list[0].port, 22)
        XCTAssertEqual(list[0].services, [])
        XCTAssertFalse(list[0].collapsed)
        XCTAssertEqual(list[1].port, 2200)
        XCTAssertEqual(list[1].services, ["nginx"])
        XCTAssertEqual(list[0].auth, .system)
    }

    func testAuthRoundTripAndConnectionDiff() throws {
        var a = ServerConfig(name: "n", host: "h", user: "u", auth: .password)
        let data = try JSONEncoder().encode(a)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("secret"))
        let b = try JSONDecoder().decode(ServerConfig.self, from: data)
        XCTAssertEqual(b.auth, .password)
        XCTAssertTrue(SSHAuthKind.password.isBuiltIn)
        XCTAssertFalse(SSHAuthKind.system.isBuiltIn)
        var c = b
        c.auth = .key
        XCTAssertTrue(c.connectionDiffers(from: b))
        a.collapsed = true
        XCTAssertFalse(a.connectionDiffers(from: b))
        // An unknown auth value from a newer version falls back to .system.
        let json = #"{"host":"h","auth":"kerberos"}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8)).auth, .system)
    }

    func testSSHCommandAndURL() {
        let cfg = ServerConfig(name: "w", host: "example.com", user: "root", port: 2222)
        XCTAssertEqual(cfg.sshCommand, "ssh -p 2222 root@example.com")
        XCTAssertEqual(cfg.sshURL?.absoluteString, "ssh://root@example.com:2222")
        XCTAssertEqual(ServerConfig(name: "w", host: "h", user: "").sshURL?.absoluteString, "ssh://h")
    }

    // MARK: Linux stream

    private let linuxBlock = """
    ##HOST web-01
    ##OS Linux
    ##BEGIN 1
    cpu  100 0 100 800 0 0 0 0 0 0
    MemTotal:       16000000 kB
    MemFree:         1000000 kB
    MemAvailable:    8000000 kB
    Buffers:          100000 kB
    Cached:          2000000 kB
    ##UP 1000.50 3000.00
    ##LOAD 0.42 0.37 0.31 1/234 5678
    ##DF
    Filesystem     1-blocks        Used   Available Capacity Mounted on
    /dev/sda1    100000000000 40000000000 60000000000      40% /
    /dev/sda1    100000000000 40000000000 60000000000      40% /var/lib/docker/overlay
    /dev/sdb1    200000000000 50000000000 150000000000     25% /mnt/data disk
    /dev/sda2      1000000000   100000000   900000000      10% /boot
    ##NET
      lo: 999 0 0 0 0 0 0 0 999 0 0 0 0 0 0 0
      eth0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0
      veth123: 500 5 0 0 0 0 0 0 500 5 0 0 0 0 0 0
    ##EXTRA
    ##REBOOT 1
    ##SVC nginx active
    ##SVC postgresql failed
    ##DOCKER
    running
    running
    exited
    ##UPDATES 7
    ##END

    """

    func testLinuxBlock() {
        let p = RemoteStreamParser()
        let out = p.feed(Data(linuxBlock.utf8), now: 10)
        XCTAssertEqual(out.hostname, "web-01")
        XCTAssertEqual(out.os, "Linux")
        XCTAssertEqual(out.samples.count, 1)
        let r = out.samples[0]
        XCTAssertEqual(r.cpuTotal, 1000)
        XCTAssertEqual(r.cpuIdle, 800)
        XCTAssertEqual(r.memTotal, 16_000_000 * 1024)
        XCTAssertEqual(r.memAvailable, 8_000_000 * 1024)
        XCTAssertEqual(r.uptime, 1000.5)
        XCTAssertEqual(r.load, [0.42, 0.37, 0.31])
        XCTAssertEqual(r.disks?.map(\.mount), ["/", "/mnt/data disk"])
        XCTAssertEqual(r.netRx, 1000)
        XCTAssertEqual(r.netTx, 2000)
        XCTAssertTrue(r.extrasRan)
        XCTAssertEqual(r.rebootRequired, true)
        XCTAssertEqual(r.services, [ServiceState(name: "nginx", state: "active"),
                                    ServiceState(name: "postgresql", state: "failed")])
        XCTAssertEqual(r.docker, DockerSummary(running: 2, total: 3))
        XCTAssertEqual(r.pendingUpdates, 7)
    }

    func testSplitChunksAndNoiseOutsideBlocks() {
        let p = RemoteStreamParser()
        var samples: [RawSample] = []
        let data = Data(("Welcome to Ubuntu!\n" + linuxBlock).utf8)
        var i = 0
        while i < data.count {
            let end = min(i + 7, data.count)
            samples += p.feed(data.subdata(in: i..<end), now: 1).samples
            i = end
        }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].load.count, 3)
    }

    func testMetricsDeltas() {
        var m = RemoteMetrics()
        var s = RemoteSnapshot()
        var a = RawSample()
        a.cpuTotal = 1000; a.cpuIdle = 800; a.netRx = 1000; a.netTx = 0; a.clock = 100
        a.memTotal = 1000; a.memAvailable = 250
        m.apply(a, to: &s)
        XCTAssertEqual(s.cpu, 0)
        XCTAssertEqual(s.memUsed, 750)
        var b = RawSample()
        b.cpuTotal = 1100; b.cpuIdle = 850; b.netRx = 3000; b.netTx = 500; b.clock = 102
        m.apply(b, to: &s)
        XCTAssertEqual(s.cpu, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.netIn, 1000, accuracy: 1e-9)
        XCTAssertEqual(s.netOut, 250, accuracy: 1e-9)
        // Counter reset clamps to zero instead of a huge number.
        var c = RawSample()
        c.netRx = 10; c.netTx = 10; c.clock = 104
        m.apply(c, to: &s)
        XCTAssertEqual(s.netIn, 0)
    }

    func testExtrasPersistUntilNextExtrasBlock() {
        var m = RemoteMetrics()
        var s = RemoteSnapshot()
        var a = RawSample()
        a.extrasRan = true; a.rebootRequired = true
        a.services = [ServiceState(name: "x", state: "failed")]
        m.apply(a, to: &s)
        m.apply(RawSample(), to: &s)
        XCTAssertEqual(s.rebootRequired, true)
        XCTAssertEqual(s.downServices.count, 1)
        XCTAssertEqual(WidgetServer.warnings(for: s), ["x failed", "reboot required"])
    }

    func testOldKernelMemFallback() {
        let text = "##BEGIN 1\nMemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 250 kB\n##END\n"
        let r = RemoteStreamParser().feed(Data(text.utf8)).samples[0]
        XCTAssertEqual(r.memAvailable, 400 * 1024)
    }

    // MARK: macOS stream

    func testDarwinBlock() {
        let text = """
        ##HOST mini
        ##OS Darwin
        ##BEGIN 1024
        ##MEMSIZE 17179869184
        ##LOAD  1.50 1.20 1.00
        ##BOOT { sec = 1700000000, usec = 123 } Tue Nov 14 22:13:20 2023
        ##NOW 1700086400
        ##TOPCPU CPU usage: 10.00% user, 15.00% sys, 75.00% idle
        ##VMSTAT
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                               10000.
        Pages active:                            200000.
        Pages wired down:                        100000.
        Pages occupied by compressor:             50000.
        ##DF
        Filesystem     1024-blocks      Used Available Capacity  Mounted on
        /dev/disk3s1s1   971350180  10000000 600000000     2%    /
        devfs                  205       205         0   100%    /dev
        /dev/disk3s5     971350180 350000000 600000000    37%    /System/Volumes/Data
        map auto_home            0         0         0   100%    /System/Volumes/Data/home
        /dev/disk5s1     976000000 476000000 500000000    49%    /Volumes/Backup
        ##NETSTAT
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                         1000     0     500000     1000     0     500000     0
        en0        1500  <Link#11>   aa:bb:cc:dd:ee:ff  123456     0  900000000    65432     0   12000000     0
        en0        1500  192.168.1     192.168.1.5      123456     -  900000000    65432     -   12000000     -
        en5*       1500  <Link#12>                          10     0       1000       10     0       2000     0
        utun0      1380  <Link#13>                       50000     0   80000000    40000     0    7000000     0
        ##END

        """
        let out = RemoteStreamParser().feed(Data(text.utf8))
        XCTAssertEqual(out.os, "Darwin")
        let r = out.samples[0]
        XCTAssertEqual(r.cpuBusy!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.memTotal, 17_179_869_184)
        XCTAssertEqual(r.memAvailable, 17_179_869_184 - 350_000 * 16384)
        XCTAssertEqual(r.load, [1.5, 1.2, 1.0])
        XCTAssertEqual(r.uptime, 86400)
        XCTAssertEqual(r.clock, 1_700_086_400)
        XCTAssertEqual(r.disks?.map(\.mount), ["/", "/Volumes/Backup"])
        let root = r.disks![0]
        XCTAssertEqual(root.used, (971_350_180 - 600_000_000) * 1024)   // container usage
        XCTAssertEqual(r.netRx, 900_001_000)
        XCTAssertEqual(r.netTx, 12_002_000)
    }

    func testTopCPUAndBootParsing() {
        XCTAssertNil(RemoteParse.topCPUBusy(""))
        XCTAssertEqual(RemoteParse.topCPUBusy("CPU usage: 1.0% user, 1.0% sys, 98.0% idle")!, 0.02, accuracy: 1e-9)
        XCTAssertEqual(RemoteParse.bootTime("{ sec = 42, usec = 0 }"), 42)
        XCTAssertNil(RemoteParse.bootTime("garbage"))
    }
}
