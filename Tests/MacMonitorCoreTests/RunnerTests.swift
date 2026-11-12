import XCTest
@testable import MacMonitorCore

final class RunnerTests: XCTestCase {
    func testProcessList() {
        let idle = RunnerProbe.parseProcessList("/opt/actions-runner/bin/Runner.Listener run\n")
        XCTAssertEqual(idle.first?.status, .online)
        let busy = RunnerProbe.parseProcessList("Runner.Listener run\nRunner.Worker spawnclient 12\n")
        XCTAssertEqual(busy.first?.status, .busy)
        XCTAssertTrue(RunnerProbe.parseProcessList("ssh -T user@host\n").isEmpty)
    }

    func testGitHubJSON() throws {
        let json = Data(#"{"runners":[{"id":4,"name":"mini","status":"online","busy":true},{"id":5,"name":"off","status":"offline","busy":false}]}"#.utf8)
        let rows = RunnerProbe.parseGitHub(json)
        XCTAssertEqual(rows.map(\.status), [.busy, .offline])
        XCTAssertEqual(rows.map(\.source), [.github, .github])
        XCTAssertTrue(RunnerProbe.parseGitHub(Data("[]".utf8)).isEmpty)
        XCTAssertEqual(RunnerProbe.runnersURL(repo: "expertosa/MacMonitor")?.host, "api.github.com")
        XCTAssertNil(RunnerProbe.runnersURL(repo: "not a repo"))
        XCTAssertNil(RunnerProbe.runnersURL(repo: "a/b/c"))
    }

    func testVolumeAlerts() {
        let engine = VolumeAlertEngine()
        XCTAssertTrue(engine.evaluate(path: "", mounted: false, freeFraction: nil, minimumFreeFraction: 0.1).isEmpty)
        let missing = engine.evaluate(path: "/Volumes/Data", mounted: false, freeFraction: nil, minimumFreeFraction: 0.1)
        XCTAssertEqual(missing.map(\.id), ["volume-missing"])
        XCTAssertTrue(engine.evaluate(path: "/Volumes/Data", mounted: false, freeFraction: nil, minimumFreeFraction: 0.1).isEmpty)
        let back = engine.evaluate(path: "/Volumes/Data", mounted: true, freeFraction: 0.5, minimumFreeFraction: 0.1)
        XCTAssertEqual(back.map(\.title), ["/Volumes/Data is mounted"])
        let low = engine.evaluate(path: "/Volumes/Data", mounted: true, freeFraction: 0.05, minimumFreeFraction: 0.1)
        XCTAssertEqual(low.map(\.id), ["volume-low"])
        XCTAssertTrue(engine.evaluate(path: "/Volumes/Data", mounted: true, freeFraction: 0.04, minimumFreeFraction: 0.1).isEmpty)
    }
}
