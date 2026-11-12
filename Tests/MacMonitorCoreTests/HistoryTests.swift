import XCTest
@testable import MacMonitorCore

final class HistoryTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func testMinuteBucketsAverageAndQuarterStaysOne() {
        var store = HistoryStore()
        let t0 = date(1_700_000_000) // aligned enough; fold uses floor
        let start = HistoryStore.bucketStart(t0, width: HistoryStore.minuteWidth)
        store.record(hostID: "local", at: start.addingTimeInterval(5),
                      cpu: 0.2, memory: 0.4, disk: 0.5, netIn: 100, netOut: 40)
        store.record(hostID: "local", at: start.addingTimeInterval(40),
                      cpu: 0.6, memory: 0.8, disk: 0.7, netIn: 300, netOut: 80)

        let day = store.series(hostID: "local", range: .day, now: start.addingTimeInterval(50))
        XCTAssertEqual(day.count, 1)
        XCTAssertEqual(day[0].count, 2)
        XCTAssertEqual(day[0].cpu, 0.4, accuracy: 0.0001)
        XCTAssertEqual(day[0].memory, 0.6, accuracy: 0.0001)
        XCTAssertEqual(day[0].disk, 0.6, accuracy: 0.0001)
        XCTAssertEqual(day[0].netIn, 200, accuracy: 0.0001)
        XCTAssertEqual(day[0].netOut, 60, accuracy: 0.0001)

        let week = store.series(hostID: "local", range: .week, now: start.addingTimeInterval(50))
        XCTAssertEqual(week.count, 1)
        XCTAssertEqual(week[0].count, 2)
        XCTAssertFalse(store.showsChart(hostID: "local", now: start.addingTimeInterval(50)))
    }

    func testSeparateMinuteBucketsAndChartThreshold() {
        var store = HistoryStore()
        let start = HistoryStore.bucketStart(date(1_700_000_100), width: 60)
        store.record(hostID: "local", at: start, cpu: 0.1, memory: 0.1, disk: 0.1, netIn: 1, netOut: 1)
        store.record(hostID: "local", at: start.addingTimeInterval(61),
                      cpu: 0.9, memory: 0.2, disk: 0.3, netIn: 2, netOut: 3)
        let now = start.addingTimeInterval(70)
        let day = store.series(hostID: "local", range: .day, now: now)
        XCTAssertEqual(day.count, 2)
        XCTAssertEqual(day.map(\.cpu), [0.1, 0.9])
        XCTAssertTrue(store.showsChart(hostID: "local", now: now))
        XCTAssertEqual(store.series(hostID: "local", range: .week, now: now).count, 1)
    }

    func testRetentionDropsDayButKeepsWeekAndDropsBoth() {
        var store = HistoryStore()
        let now = date(1_800_000_000)
        store.record(hostID: "srv", at: now.addingTimeInterval(-25 * 3600),
                      cpu: 0.3, memory: 0.3, disk: 0.3, netIn: 3, netOut: 3)
        store.record(hostID: "srv", at: now.addingTimeInterval(-2 * 3600),
                      cpu: 0.5, memory: 0.5, disk: 0.5, netIn: 5, netOut: 5)
        store.record(hostID: "other", at: now.addingTimeInterval(-8 * 24 * 3600),
                      cpu: 1, memory: 1, disk: 1, netIn: 9, netOut: 9)

        XCTAssertEqual(store.series(hostID: "srv", range: .day, now: now).count, 1)
        XCTAssertEqual(store.series(hostID: "srv", range: .day, now: now)[0].cpu, 0.5, accuracy: 0.0001)
        XCTAssertEqual(store.series(hostID: "srv", range: .week, now: now).count, 2)
        XCTAssertTrue(store.series(hostID: "other", range: .day, now: now).isEmpty)
        XCTAssertTrue(store.series(hostID: "other", range: .week, now: now).isEmpty)
        XCTAssertTrue(store.series(hostID: "missing", range: .day, now: now).isEmpty)
    }

    func testHostsStayIndependentAndRoundTrip() throws {
        var store = HistoryStore()
        let now = date(1_700_100_000)
        store.record(hostID: HistoryStore.localHostID, at: now, cpu: 0.2, memory: 0.2, disk: 0.2, netIn: 1, netOut: 2)
        store.record(hostID: "abc", at: now, cpu: 0.8, memory: 0.1, disk: 0.4, netIn: 8, netOut: 7)
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(HistoryStore.self, from: data)
        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.series(hostID: "abc", range: .day, now: now.addingTimeInterval(10))[0].netOut, 7)
        XCTAssertEqual(decoded.hostIDs, ["abc", "local"])
    }
}
