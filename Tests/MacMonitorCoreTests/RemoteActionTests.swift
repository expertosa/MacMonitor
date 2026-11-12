import XCTest
@testable import MacMonitorCore

final class RemoteActionTests: XCTestCase {
    func testCommandsRejectUnsafeNames() {
        XCTAssertNil(RemoteAction.restartService("nginx;reboot").command())
        XCTAssertNil(RemoteAction.restartContainer("bad name").command())
        XCTAssertNil(RemoteAction.restartContainer("-api").command())
        let service = RemoteAction.restartService("nginx")
        XCTAssertEqual(service.command(), "sudo -n systemctl restart -- nginx")
        XCTAssertEqual(service.remoteShell(), "sh -c 'sudo -n systemctl restart -- nginx'")
        let container = RemoteAction.restartContainer("api_1")
        XCTAssertTrue(container.command()?.contains("docker restart -- api_1") == true)
        let updates = RemoteAction.installUpdates.remoteShell()
        XCTAssertNotNil(updates)
        XCTAssertFalse(inner(updates!).contains("'"))
        XCTAssertNil(RemoteAction.container(from: "bad name|running"))
        XCTAssertEqual(RemoteAction.container(from: "api_1|exited")?.running, false)
    }

    func testRemoteShellHasNoNestedQuotes() {
        for action in [RemoteAction.restartService("nginx.service"), .restartContainer("db"), .installUpdates] {
            let shell = action.remoteShell()
            XCTAssertNotNil(shell)
            XCTAssertTrue(shell!.hasPrefix("sh -c '"))
            XCTAssertTrue(shell!.hasSuffix("'"))
            XCTAssertFalse(inner(shell!).contains("'"))
        }
    }

    private func inner(_ shell: String) -> String {
        String(shell.dropFirst("sh -c '".count).dropLast())
    }
}
