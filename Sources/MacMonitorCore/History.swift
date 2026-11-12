import Foundation

/// CPU, memory, disk and network samples kept per host.
///
/// Two resolutions are stored at once:
/// - one-minute averages for the last 24 hours
/// - fifteen-minute averages for the last 7 days
/// Older buckets are dropped. Nothing here touches the disk; the app persists the store.
public enum HistoryRange: String, Codable, CaseIterable, Sendable, Identifiable {
    case day
    case week

    public var id: String { rawValue }

    public var retain: TimeInterval {
        switch self {
        case .day: return HistoryStore.day
        case .week: return HistoryStore.week
        }
    }
}

public struct HistoryBucket: Codable, Equatable, Sendable {
    public var start: Date
    /// Averages over `count` samples. CPU, memory and disk are fractions in 0...1.
    /// Network rates are bytes per second.
    public var cpu: Double
    public var memory: Double
    public var disk: Double
    public var netIn: Double
    public var netOut: Double
    public var count: Int

    public init(start: Date, cpu: Double, memory: Double, disk: Double,
                netIn: Double, netOut: Double, count: Int = 1) {
        self.start = start
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.netIn = netIn
        self.netOut = netOut
        self.count = count
    }

    mutating func add(cpu: Double, memory: Double, disk: Double, netIn: Double, netOut: Double) {
        let n = Double(count)
        let m = n + 1
        self.cpu = (self.cpu * n + cpu) / m
        self.memory = (self.memory * n + memory) / m
        self.disk = (self.disk * n + disk) / m
        self.netIn = (self.netIn * n + netIn) / m
        self.netOut = (self.netOut * n + netOut) / m
        count += 1
    }
}

public struct HostHistory: Codable, Equatable, Sendable {
    public var hostID: String
    public var minute: [HistoryBucket]
    public var quarter: [HistoryBucket]

    public init(hostID: String, minute: [HistoryBucket] = [], quarter: [HistoryBucket] = []) {
        self.hostID = hostID
        self.minute = minute
        self.quarter = quarter
    }
}

public struct HistoryStore: Codable, Equatable, Sendable {
    public static let localHostID = "local"
    public static let minuteWidth: TimeInterval = 60
    public static let quarterWidth: TimeInterval = 15 * 60
    public static let day: TimeInterval = 24 * 60 * 60
    public static let week: TimeInterval = 7 * 24 * 60 * 60

    public private(set) var hosts: [String: HostHistory]

    public init(hosts: [String: HostHistory] = [:]) {
        self.hosts = hosts
    }

    public var hostIDs: [String] { hosts.keys.sorted() }

    public mutating func record(hostID: String, at time: Date,
                                 cpu: Double, memory: Double, disk: Double,
                                 netIn: Double, netOut: Double) {
        var host = hosts[hostID] ?? HostHistory(hostID: hostID)
        host.minute = Self.fold(host.minute, width: Self.minuteWidth, retain: Self.day,
                                 time: time, cpu: cpu, memory: memory, disk: disk, netIn: netIn, netOut: netOut)
        host.quarter = Self.fold(host.quarter, width: Self.quarterWidth, retain: Self.week,
                                  time: time, cpu: cpu, memory: memory, disk: disk, netIn: netIn, netOut: netOut)
        hosts[hostID] = host
    }

    /// Buckets for the range, oldest first. Empty when the host has never been recorded.
    public func series(hostID: String, range: HistoryRange, now: Date = Date()) -> [HistoryBucket] {
        guard let host = hosts[hostID] else { return [] }
        let buckets = range == .day ? host.minute : host.quarter
        let cutoff = now.addingTimeInterval(-range.retain)
        return buckets.filter { $0.start >= cutoff }
    }

    public func showsChart(hostID: String, now: Date = Date()) -> Bool {
        series(hostID: hostID, range: .day, now: now).count >= 2
            || series(hostID: hostID, range: .week, now: now).count >= 2
    }

    static func bucketStart(_ time: Date, width: TimeInterval) -> Date {
        let t = time.timeIntervalSince1970
        return Date(timeIntervalSince1970: floor(t / width) * width)
    }

    private static func fold(_ buckets: [HistoryBucket], width: TimeInterval, retain: TimeInterval,
                              time: Date, cpu: Double, memory: Double, disk: Double,
                              netIn: Double, netOut: Double) -> [HistoryBucket] {
        let start = bucketStart(time, width: width)
        var next = buckets.filter { $0.start >= time.addingTimeInterval(-retain - width) }
        if let i = next.lastIndex(where: { $0.start == start }) {
            next[i].add(cpu: cpu, memory: memory, disk: disk, netIn: netIn, netOut: netOut)
        } else {
            next.append(HistoryBucket(start: start, cpu: cpu, memory: memory, disk: disk,
                                       netIn: netIn, netOut: netOut))
            next.sort { $0.start < $1.start }
        }
        return next
    }
}
