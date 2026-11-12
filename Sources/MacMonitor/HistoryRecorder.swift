import Foundation
import MacMonitorCore

/// Records this Mac and each server into `HistoryStore` and writes it under Application Support.
/// Snapshot mode does not record, so README renders stay the same until real samples exist.
@MainActor
final class HistoryRecorder {
    static let shared = HistoryRecorder()

    private(set) var store = HistoryStore()
    private var lastSave = Date.distantPast
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.url = base.appendingPathComponent("MacMonitor/history.json")
        }
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? decoder.decode(HistoryStore.self, from: data) {
            store = decoded
        }
    }

    func recordLocal(_ snapshot: Snapshot, at time: Date = Date()) {
        guard !SnapshotExporter.isActive else { return }
        let disk = (snapshot.volumes.first { $0.id == "/" } ?? snapshot.volumes.first)?.usedFraction ?? 0
        store.record(hostID: HistoryStore.localHostID, at: time,
                      cpu: snapshot.cpu, memory: snapshot.memFraction, disk: disk,
                      netIn: snapshot.netIn, netOut: snapshot.netOut)
        saveIfNeeded(now: time)
    }

    func recordServer(id: UUID, snapshot: RemoteSnapshot, at time: Date = Date()) {
        guard snapshot.hasData, !SnapshotExporter.isActive else { return }
        let disk = (snapshot.disks.first { $0.mount == "/" } ?? snapshot.fullestDisk)?.usedFraction ?? 0
        store.record(hostID: id.uuidString, at: time,
                      cpu: snapshot.cpu, memory: snapshot.memFraction, disk: disk,
                      netIn: snapshot.netIn, netOut: snapshot.netOut)
        saveIfNeeded(now: time)
    }

    func day(_ hostID: String, now: Date = Date()) -> [HistoryBucket] {
        store.series(hostID: hostID, range: .day, now: now)
    }

    func week(_ hostID: String, now: Date = Date()) -> [HistoryBucket] {
        store.series(hostID: hostID, range: .week, now: now)
    }

    /// Included in the panel layout key so the window grows when a chart first appears.
    var layoutKey: [Int] {
        let now = Date()
        let servers = store.hostIDs.filter { $0 != HistoryStore.localHostID && store.showsChart(hostID: $0, now: now) }
        return [store.showsChart(hostID: HistoryStore.localHostID, now: now) ? 1 : 0, servers.count]
    }

    private func saveIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastSave) >= 30 else { return }
        lastSave = now
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try encoder.encode(store).write(to: url, options: .atomic)
        } catch {
            // History is a convenience. A full disk must not stop monitoring.
        }
    }
}
