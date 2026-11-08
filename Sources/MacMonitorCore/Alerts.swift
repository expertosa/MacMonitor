import Foundation

/// User-configurable alert thresholds (stored as JSON in the user defaults).
public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var cpuPercent = 90.0
    public var cpuMinutes = 5.0
    public var memoryPressure = true          // notify on critical memory pressure
    public var diskPercent = 90.0
    public var batteryPercent = 15.0
    public var serverOfflineMinutes = 2.0
    public var serverDiskPercent = 90.0
    public var serverCPUPercent = 95.0
    public var serverCPUMinutes = 10.0
    public var services = true
    public var reboot = true

    public init() {}

    // Tolerant decoding so new fields don't reset older saved settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? d.cpuPercent
        cpuMinutes = try c.decodeIfPresent(Double.self, forKey: .cpuMinutes) ?? d.cpuMinutes
        memoryPressure = try c.decodeIfPresent(Bool.self, forKey: .memoryPressure) ?? d.memoryPressure
        diskPercent = try c.decodeIfPresent(Double.self, forKey: .diskPercent) ?? d.diskPercent
        batteryPercent = try c.decodeIfPresent(Double.self, forKey: .batteryPercent) ?? d.batteryPercent
        serverOfflineMinutes = try c.decodeIfPresent(Double.self, forKey: .serverOfflineMinutes) ?? d.serverOfflineMinutes
        serverDiskPercent = try c.decodeIfPresent(Double.self, forKey: .serverDiskPercent) ?? d.serverDiskPercent
        serverCPUPercent = try c.decodeIfPresent(Double.self, forKey: .serverCPUPercent) ?? d.serverCPUPercent
        serverCPUMinutes = try c.decodeIfPresent(Double.self, forKey: .serverCPUMinutes) ?? d.serverCPUMinutes
        services = try c.decodeIfPresent(Bool.self, forKey: .services) ?? d.services
        reboot = try c.decodeIfPresent(Bool.self, forKey: .reboot) ?? d.reboot
    }
}

public struct AlertInput: Sendable {
    public struct Volume: Sendable {
        public var id: String, name: String, usedFraction: Double
        public init(id: String, name: String, usedFraction: Double) {
            self.id = id; self.name = name; self.usedFraction = usedFraction
        }
    }
    public struct Server: Sendable {
        public var id: UUID
        public var name: String
        public var offline: Bool              // status is .error
        public var online: Bool               // receiving data
        public var cpu: Double
        public var disks: [RemoteDisk]
        public var services: [ServiceState]
        public var rebootRequired: Bool
        public init(id: UUID, name: String, offline: Bool, online: Bool, cpu: Double = 0,
                    disks: [RemoteDisk] = [], services: [ServiceState] = [], rebootRequired: Bool = false) {
            self.id = id; self.name = name; self.offline = offline; self.online = online; self.cpu = cpu
            self.disks = disks; self.services = services; self.rebootRequired = rebootRequired
        }
    }

    public var cpu: Double = 0
    public var memoryPressureCritical = false
    public var volumes: [Volume] = []
    public var batteryPercent: Double?        // nil = no battery
    public var batteryCharging = false
    public var servers: [Server] = []
    public init() {}
}

public struct AlertEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public init(id: String, title: String, body: String) { self.id = id; self.title = title; self.body = body }
}

/// Turns periodic measurements into one-shot notifications. A condition must hold for its
/// duration before it fires, fires once, and re-arms only after it clears (with a small
/// hysteresis for percentages so values hovering at the threshold don't flap).
public final class AlertEngine {
    private var since: [String: Date] = [:]
    private var fired: Set<String> = []

    public init() {}

    public func reset() { since.removeAll(); fired.removeAll() }

    public func evaluate(_ input: AlertInput, settings s: AlertSettings, now: Date = Date()) -> [AlertEvent] {
        guard s.enabled else { reset(); return [] }
        var events: [AlertEvent] = []
        var seen: Set<String> = []

        func track(_ key: String, active: Bool, hold: TimeInterval, fire: () -> AlertEvent,
                   resolve: (() -> AlertEvent)? = nil) {
            seen.insert(key)
            if active {
                let start = since[key] ?? now
                since[key] = start
                if !fired.contains(key), now.timeIntervalSince(start) >= hold {
                    fired.insert(key)
                    events.append(fire())
                }
            } else {
                since[key] = nil
                if fired.remove(key) != nil, let resolve { events.append(resolve()) }
            }
        }
        func over(_ key: String, _ value: Double, _ threshold: Double) -> Bool {
            value >= threshold || (fired.contains(key) && value >= threshold - 2)
        }

        // This Mac
        let cpuPct = input.cpu * 100
        track("cpu", active: over("cpu", cpuPct, s.cpuPercent), hold: s.cpuMinutes * 60) {
            AlertEvent(id: "cpu", title: "High CPU usage",
                       body: String(format: "CPU has been above %.0f%% for %.0f min (now %.0f%%).",
                                    s.cpuPercent, s.cpuMinutes, cpuPct))
        }
        track("mempressure", active: s.memoryPressure && input.memoryPressureCritical, hold: 30) {
            AlertEvent(id: "mempressure", title: "Memory pressure is critical",
                       body: "macOS is running low on memory. Quit apps you don't need.")
        }
        for v in input.volumes {
            let key = "disk:" + v.id
            let pct = v.usedFraction * 100
            track(key, active: over(key, pct, s.diskPercent), hold: 0) {
                AlertEvent(id: key, title: "\(v.name) is almost full",
                           body: String(format: "%.0f%% of the disk is used.", pct))
            }
        }
        if let b = input.batteryPercent {
            track("battery", active: !input.batteryCharging && b <= s.batteryPercent, hold: 0) {
                AlertEvent(id: "battery", title: "Battery low",
                           body: String(format: "%.0f%% remaining. Connect the charger.", b))
            }
        }

        // Servers
        for srv in input.servers {
            let p = "srv:\(srv.id.uuidString):"
            track(p + "offline", active: srv.offline, hold: s.serverOfflineMinutes * 60, fire: {
                AlertEvent(id: p + "offline", title: "\(srv.name) is unreachable",
                           body: String(format: "No data for %.0f min.", s.serverOfflineMinutes))
            }, resolve: {
                AlertEvent(id: p + "offline", title: "\(srv.name) is back online", body: "Monitoring resumed.")
            })
            guard srv.online else { continue }
            let cpuKey = p + "cpu"
            let scpu = srv.cpu * 100
            track(cpuKey, active: over(cpuKey, scpu, s.serverCPUPercent), hold: s.serverCPUMinutes * 60) {
                AlertEvent(id: cpuKey, title: "High CPU on \(srv.name)",
                           body: String(format: "CPU has been above %.0f%% for %.0f min.",
                                        s.serverCPUPercent, s.serverCPUMinutes))
            }
            for d in srv.disks {
                let key = p + "disk:" + d.mount
                let pct = d.usedFraction * 100
                track(key, active: over(key, pct, s.serverDiskPercent), hold: 0) {
                    AlertEvent(id: key, title: "\(srv.name): \(d.mount) is almost full",
                               body: String(format: "%.0f%% used.", pct))
                }
            }
            if s.services {
                for svc in srv.services {
                    let key = p + "svc:" + svc.name
                    track(key, active: svc.isDown, hold: 0, fire: {
                        AlertEvent(id: key, title: "\(svc.name) is \(svc.state) on \(srv.name)",
                                   body: "systemctl reports the service is not active.")
                    }, resolve: {
                        AlertEvent(id: key, title: "\(svc.name) is running again on \(srv.name)", body: "")
                    })
                }
            }
            if s.reboot {
                track(p + "reboot", active: srv.rebootRequired, hold: 0) {
                    AlertEvent(id: p + "reboot", title: "\(srv.name) needs a reboot",
                               body: "Installed updates require a restart (/var/run/reboot-required).")
                }
            }
        }

        // Forget conditions for things that disappeared (removed servers, ejected disks).
        for key in Set(since.keys).union(fired) where !seen.contains(key) {
            since[key] = nil
            fired.remove(key)
        }
        return events
    }
}
