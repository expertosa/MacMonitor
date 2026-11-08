import SwiftUI
import MacMonitorCore

// Views used by the WidgetKit extension. They live in the shared UI module so the app can
// also render them (MM_WIDGET_SNAPSHOT) for screenshots and visual checks without WidgetKit.

public struct MacWidgetData: Equatable {
    public var hostName: String
    public var cpu: Double
    public var memory: MemoryStats
    public var bootVolume: Volume?
    public var netIn: Double
    public var netOut: Double
    public var battery: BatteryStats?
    public var gpu: Double?

    public init(hostName: String, cpu: Double, memory: MemoryStats, bootVolume: Volume?,
                netIn: Double, netOut: Double, battery: BatteryStats?, gpu: Double?) {
        self.hostName = hostName; self.cpu = cpu; self.memory = memory; self.bootVolume = bootVolume
        self.netIn = netIn; self.netOut = netOut; self.battery = battery; self.gpu = gpu
    }

    public static var sample: MacWidgetData {
        var m = MemoryStats()
        m.total = 16 * 1_073_741_824
        m.used = UInt64(9.3 * 1_073_741_824)
        m.pressure = .normal
        m.swapTotal = 2 * 1_073_741_824
        m.swapUsed = UInt64(0.4 * 1_073_741_824)
        return MacWidgetData(hostName: "MacBook Pro", cpu: 0.27, memory: m,
                             bootVolume: Volume(id: "/", name: "Macintosh HD", free: 212_000_000_000,
                                                total: 494_000_000_000),
                             netIn: 1_240_000, netOut: 86_000,
                             battery: BatteryStats(percent: 76, charging: false, onAC: false, watts: 7.4),
                             gpu: 0.12)
    }
}

public extension WidgetServer {
    static var samples: [WidgetServer] {
        [WidgetServer(id: UUID(), name: "web-01", state: .online, cpu: 0.23, memFraction: 0.41,
                      diskFraction: 0.37, diskMount: "/", load1: 0.42),
         WidgetServer(id: UUID(), name: "db-01", state: .online, cpu: 0.61, memFraction: 0.78,
                      diskFraction: 0.91, diskMount: "/var/lib/postgresql", load1: 2.10,
                      warnings: ["reboot required"]),
         WidgetServer(id: UUID(), name: "backup", state: .error, message: "Connection refused")]
    }
}

public enum WidgetFamilySize { case small, medium, large }

/// Background used by both widgets (also used as containerBackground on macOS 14+).
public struct WidgetBackground: View {
    @Environment(\.panelStyle) private var style
    public init() {}
    public var body: some View {
        ZStack {
            (style.palette.isDark ? Color(hex: 0x1B1714) : Color(hex: 0xFFF3E6))
            PanelBackground()
        }
    }
}

public struct MacWidgetView: View {
    @Environment(\.panelStyle) private var style
    let data: MacWidgetData
    let servers: [WidgetServer]
    let size: WidgetFamilySize

    public init(data: MacWidgetData, servers: [WidgetServer] = [], size: WidgetFamilySize) {
        self.data = data; self.servers = servers; self.size = size
    }

    public var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    private var title: some View {
        Text(data.hostName)
            .font(style.font(11, rounded: false))
            .foregroundColor(style.palette.ink)
            .lineLimit(1)
    }

    private var small: some View {
        VStack(spacing: 6) {
            title
            CPURing(load: data.cpu, diameter: 64, innerDiameter: 28)
            HStack(spacing: 8) {
                miniStat("RAM", data.memory.fraction)
                if let v = data.bootVolume { miniStat("SSD", v.usedFraction) }
            }
        }
    }

    private func miniStat(_ label: String, _ f: Double) -> some View {
        VStack(spacing: 2) {
            Text(Fmt.pct(f)).font(style.font(12, mono: true)).foregroundColor(style.palette.ink)
            Text(label).font(style.font(8.5)).foregroundColor(style.palette.label.opacity(0.8))
        }
    }

    private func meters(full: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CompactMeter(icon: "memorychip", title: "Memory",
                         detail: "\(Fmt.gb(data.memory.used))/\(Fmt.gb(data.memory.total)) GB",
                         value: Fmt.pct(data.memory.fraction), fraction: data.memory.fraction)
            if let v = data.bootVolume {
                CompactMeter(icon: "internaldrive", title: v.name, detail: "\(Fmt.diskGB(v.free)) GB free",
                             value: Fmt.pct(v.usedFraction), fraction: v.usedFraction)
            }
            if let b = data.battery {
                CompactMeter(icon: b.charging ? "battery.100.bolt" : "battery.75", title: "Battery",
                             detail: b.watts.map { Fmt.watts($0) }, value: String(format: "%.0f%%", b.percent),
                             fraction: b.percent / 100)
            }
            if let g = data.gpu, full || data.battery == nil {
                CompactMeter(icon: "cube.transparent", title: "GPU", detail: nil, value: Fmt.pct(g), fraction: g)
            }
            if full {
                CompactMeter(icon: "arrow.left.arrow.right", title: "Swap",
                             detail: "pressure \(data.memory.pressure.label)",
                             value: "\(Fmt.gb(data.memory.swapUsed)) GB",
                             fraction: data.memory.swapTotal > 0
                                ? Double(data.memory.swapUsed) / Double(data.memory.swapTotal) : 0)
            }
            HStack(spacing: 6) {
                RateChip(arrow: "↓", rate: Fmt.rate(data.netIn))
                RateChip(arrow: "↑", rate: Fmt.rate(data.netOut))
            }
        }
    }

    private var medium: some View { top(full: false) }

    private func top(full: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                title
                CPURing(load: data.cpu, diameter: 84, innerDiameter: 36)
            }
            .frame(width: 100)
            meters(full: full)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            top(full: true)
            if !servers.isEmpty {
                Rectangle().fill(style.palette.divider).frame(height: 0.5)
                ServerRows(servers: Array(servers.prefix(5)))
            }
            Spacer(minLength: 0)
        }
    }
}

public struct ServersWidgetView: View {
    @Environment(\.panelStyle) private var style
    let servers: [WidgetServer]
    let size: WidgetFamilySize
    let updated: Date?

    public init(servers: [WidgetServer], size: WidgetFamilySize, updated: Date?) {
        self.servers = servers; self.size = size; self.updated = updated
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "server.rack")
                Text("Servers").font(style.font(11, rounded: false))
                Spacer()
                let down = servers.filter { $0.state == .error }.count
                Text(down == 0 ? "\(servers.count) online" : "\(down) down")
                    .font(style.detailFont)
                    .foregroundColor(down == 0 ? style.palette.ink.opacity(0.6) : style.palette.statusError)
            }
            .foregroundColor(style.palette.label)
            if servers.isEmpty {
                Spacer(minLength: 0)
                Text("Add Linux or Mac servers in MacMonitor (Add Server… in the menu bar) to see them here.")
                    .font(style.detailFont)
                    .foregroundColor(style.palette.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ServerRows(servers: Array(servers.prefix(size == .large ? 8 : (size == .medium ? 3 : 2))),
                           compact: size == .small)
                Spacer(minLength: 0)
            }
            if let updated, size != .small {
                Text("Updated \(updated, style: .time)")
                    .font(style.font(8.5, .regular))
                    .foregroundColor(style.palette.ink.opacity(0.45))
            }
        }
    }
}

struct ServerRows: View {
    @Environment(\.panelStyle) private var style
    let servers: [WidgetServer]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            ForEach(servers) { s in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        StatusDot(s.state == .online ? .online : s.state == .connecting ? .connecting : .error)
                        Text(s.name)
                            .font(style.font(11, rounded: false))
                            .foregroundColor(style.palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if s.state == .online, !compact {
                            metric("CPU", s.cpu)
                            metric("MEM", s.memFraction)
                            metric("DSK", s.diskFraction)
                        } else if s.state == .online {
                            metric("CPU", s.cpu)
                        } else {
                            Text(s.state == .error ? "offline" : "connecting")
                                .font(style.detailFont)
                                .foregroundColor(s.state == .error ? style.palette.statusError
                                                 : style.palette.ink.opacity(0.6))
                        }
                    }
                    if !compact, let w = s.warnings.first {
                        Text(s.warnings.count > 1 ? "\(w) +\(s.warnings.count - 1)" : w)
                            .font(style.font(9, .medium))
                            .foregroundColor(style.palette.statusError)
                            .lineLimit(1)
                            .padding(.leading, style.s(13))
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: Double?) -> some View {
        let v = value ?? 0
        return HStack(spacing: 2) {
            Text(label).font(style.font(8, .semibold)).foregroundColor(style.palette.label.opacity(0.75))
            Text(value.map { Fmt.pct($0) } ?? "–")
                .font(style.font(10.5, mono: true))
                .foregroundColor(v > 0.85 ? style.palette.accentDeep : style.palette.ink)
        }
        .frame(minWidth: 52, alignment: .trailing)
    }
}
