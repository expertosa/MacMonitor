import Foundation

/// What the app publishes for the widget extension (servers are only known to the app).
public struct WidgetPayload: Codable, Equatable, Sendable {
    public var updated: Date
    public var hostName: String
    public var servers: [WidgetServer]
    public init(updated: Date, hostName: String, servers: [WidgetServer]) {
        self.updated = updated; self.hostName = hostName; self.servers = servers
    }
}

public struct WidgetServer: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case online, connecting, error }
    public var id: UUID
    public var name: String
    public var state: State
    public var message: String?
    public var cpu: Double?
    public var memFraction: Double?
    public var diskFraction: Double?       // fullest filesystem
    public var diskMount: String?
    public var load1: Double?
    public var warnings: [String]          // "reboot", "nginx failed", "3 updates", ...

    public init(id: UUID, name: String, state: State, message: String? = nil, cpu: Double? = nil,
                memFraction: Double? = nil, diskFraction: Double? = nil, diskMount: String? = nil,
                load1: Double? = nil, warnings: [String] = []) {
        self.id = id; self.name = name; self.state = state; self.message = message; self.cpu = cpu
        self.memFraction = memFraction; self.diskFraction = diskFraction; self.diskMount = diskMount
        self.load1 = load1; self.warnings = warnings
    }

    /// Short warning list derived from a snapshot (shared by the panel, menu and widget).
    public static func warnings(for s: RemoteSnapshot) -> [String] {
        var w: [String] = []
        for svc in s.downServices { w.append("\(svc.name) \(svc.state)") }
        if s.rebootRequired == true { w.append("reboot required") }
        if let n = s.pendingUpdates, n > 0 { w.append("\(n) update\(n == 1 ? "" : "s")") }
        return w
    }
}

/// JSON file in the shared App Group container. The group id must match the
/// com.apple.security.application-groups entitlement of the app and the widget.
public enum SharedStore {
    public static let appGroup = "NWPTRYJ9FL.com.tweetso.macmonitor"
    static let fileName = "widget.json"

    public static var fileURL: URL? {
        #if os(macOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
        #else
        return nil
        #endif
    }

    public static func encode(_ payload: WidgetPayload) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try? e.encode(payload)
    }

    public static func decode(_ data: Data) -> WidgetPayload? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(WidgetPayload.self, from: data)
    }

    public static func read() -> WidgetPayload? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    @discardableResult
    public static func write(_ payload: WidgetPayload) -> Bool {
        guard let url = fileURL, let data = encode(payload) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
