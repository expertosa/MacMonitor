import AppKit
import SwiftUI
import Combine
import MacMonitorCore
import MacMonitorUI

/// Tracks whether the system is in dark mode (for the "Match system" panel theme).
@MainActor
final class SystemAppearance: ObservableObject {
    static let shared = SystemAppearance()
    @Published private(set) var isDark = false
    private var observation: NSKeyValueObservation?

    private init() {
        update()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func update() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark != isDark { isDark = dark }
    }
}

extension Preferences {
    /// Snapshot-mode override: MM_SNAPSHOT_THEME=dark renders the dark palette.
    var effectiveDark: Bool {
        if let forced = ProcessInfo.processInfo.environment["MM_SNAPSHOT_THEME"] { return forced == "dark" }
        switch theme {
        case .warm: return false
        case .dark: return true
        case .auto: return SystemAppearance.shared.isDark
        }
    }

    var panelStyle: PanelStyle {
        PanelStyle(palette: effectiveDark ? .dark : .warm, scale: size.scale)
    }
}

struct MonitorView: View {
    @ObservedObject var sampler: Sampler
    @ObservedObject var remotes: RemoteManager
    @ObservedObject var prefs: Preferences
    @ObservedObject var appearance = SystemAppearance.shared
    /// ImageRenderer can't draw NSVisualEffectView materials; use a flat translucent fill instead.
    var snapshotMode: Bool = false

    var body: some View {
        let style = prefs.panelStyle
        let s = sampler.snapshot
        VStack(spacing: 0) {
            PanelHeader(title: snapshotMode ? "MacBook Pro" : LocalHost.name,
                        subtitle: "up " + Fmt.duration(ProcessInfo.processInfo.systemUptime))

            VStack(alignment: .leading, spacing: style.s(Theme.sectionSpacing)) {
                VStack(spacing: style.s(10)) {
                    CPURing(load: s.cpu, diameter: style.s(110), innerDiameter: style.s(46))
                        .frame(maxWidth: .infinity)
                    if prefs.shows(.cpuHistory) {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionRow(icon: "waveform.path.ecg", title: "Last \(historyLabel)",
                                       value: "peak " + Fmt.pct(s.cpuHistory.max() ?? 0))
                            HistoryBars(values: s.cpuHistory)
                                .frame(height: style.s(40))
                        }
                    }
                    HistoryChartCard(day: HistoryRecorder.shared.day(HistoryStore.localHostID),
                                     week: HistoryRecorder.shared.week(HistoryStore.localHostID))
                }

                if prefs.shows(.memory) {
                    VStack(alignment: .leading, spacing: 3) {
                        MeterSection(icon: "memorychip", title: "Memory",
                                     value: Fmt.pct(s.memFraction),
                                     detail: "\(Fmt.gb(s.memory.used)) of \(Fmt.gb(s.memory.total)) GB used",
                                     fraction: s.memFraction)
                        if prefs.shows(.memoryDetail) {
                            DetailLine(text: memoryDetail(s.memory),
                                       warning: s.memory.pressure == .critical || s.memory.pressure == .warning)
                        }
                    }
                }

                if prefs.shows(.gpu), let g = s.gpu {
                    CompactMeter(icon: "cube.transparent", title: "GPU", detail: nil, value: Fmt.pct(g), fraction: g)
                }

                if prefs.shows(.battery), let b = s.battery {
                    MeterSection(icon: batteryIcon(b), title: "Battery",
                                 value: String(format: "%.0f%%", b.percent),
                                 detail: batteryDetail(b), fraction: b.percent / 100)
                }

                #if !APPSTORE
                if prefs.shows(.sensors), !s.sensors.isEmpty {
                    SectionRow(icon: "thermometer.medium", title: "Sensors", value: sensorsText(s.sensors))
                }
                #endif

                if prefs.shows(.disks) {
                    ForEach(s.volumes) { vol in
                        MeterSection(icon: vol.id == "/" ? "internaldrive" : "externaldrive",
                                     title: vol.name,
                                     value: "\(Fmt.diskGB(vol.free)) GB free",
                                     detail: "of \(Fmt.diskGB(vol.total)) GB",
                                     fraction: vol.usedFraction)
                    }
                }

                if prefs.shows(.network) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionRow(icon: "network", title: "Network", value: nil)
                        HStack(spacing: 6) {
                            RateChip(arrow: "↓", rate: Fmt.rate(s.netIn))
                            RateChip(arrow: "↑", rate: Fmt.rate(s.netOut))
                        }
                    }
                }

                #if !APPSTORE
                if prefs.shows(.processes), !s.processes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionRow(icon: "list.number", title: "Top processes", value: nil)
                        ForEach(s.processes) { p in
                            HStack {
                                Text(p.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(Fmt.pct(p.cpu))
                            }
                            .font(style.detailFont)
                            .foregroundColor(style.palette.ink.opacity(0.8))
                            .padding(.leading, style.s(20))
                        }
                    }
                }
                #endif
            }
            .padding(.horizontal, style.s(Theme.hPadding))
            .padding(.top, style.s(14))
            .padding(.bottom, style.s(16))

            // One compact section per SSH server (each observes only its own sampler).
            ForEach(remotes.servers) { server in
                RemoteSection(server: server)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: style.s(Theme.panelWidth), alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelBackground(flatFill: snapshotMode))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .environment(\.panelStyle, style)
        .environment(\.colorScheme, style.palette.isDark ? .dark : .light)
    }

    private var historyLabel: String {
        let secs = sampler.historySeconds
        return secs >= 120 ? "\(secs / 60) min" : "\(secs) s"
    }

    private func memoryDetail(_ m: MemoryStats) -> String {
        var t = "Pressure \(m.pressure.label)"
        if m.swapTotal > 0 || m.swapUsed > 0 { t += " · swap \(Fmt.gb(m.swapUsed)) GB" }
        return t
    }

    private func batteryIcon(_ b: BatteryStats) -> String {
        if b.charging { return "battery.100.bolt" }
        switch b.percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryDetail(_ b: BatteryStats) -> String {
        var parts: [String] = [b.charging ? "Charging" : (b.onAC ? "On power adapter" : "On battery")]
        if let w = b.watts, w > 0.05 { parts.append(Fmt.watts(w)) }
        if let m = b.minutesRemaining {
            parts.append(Fmt.duration(Double(m) * 60) + (b.charging ? " to full" : " left"))
        }
        return parts.joined(separator: " · ")
    }

    #if !APPSTORE
    private func sensorsText(_ r: SensorReadings) -> String {
        var parts: [String] = []
        if let c = r.cpuTemp { parts.append("CPU " + Fmt.temp(c)) }
        if let g = r.gpuTemp { parts.append("GPU " + Fmt.temp(g)) }
        if let f = r.fans.first { parts.append(String(format: "%.0f rpm", f)) }
        return parts.joined(separator: "  ")
    }
    #endif
}

struct DetailLine: View {
    @Environment(\.panelStyle) private var style
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(style.detailFont)
            .foregroundColor(warning ? style.palette.statusError : style.palette.ink.opacity(0.6))
            .lineLimit(1)
    }
}

// MARK: - Remote server section

struct RemoteSection: View {
    @ObservedObject var server: RemoteSampler
    @Environment(\.panelStyle) private var style

    private var errorText: String? {
        if case .error(let msg) = server.status { return msg }
        return nil
    }

    var body: some View {
        let s = server.snapshot
        VStack(spacing: 0) {
            ServerHeader(name: server.config.name, status: server.status, snapshot: s,
                         collapsed: server.config.collapsed)
            if !server.config.collapsed {
                VStack(alignment: .leading, spacing: style.s(9)) {
                    if let errorText {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(style.font(9.5, rounded: false))
                                .foregroundColor(style.palette.statusError)
                            Text(errorText)
                                .font(style.detailFont)
                                .foregroundColor(style.palette.ink.opacity(0.75))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !s.hasData {
                        Text("Connecting to \(server.config.displayAddress)…")
                            .font(style.detailFont)
                            .foregroundColor(style.palette.ink.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        RemoteMetricsView(s: s, hideDisks: server.config.hideDisks, hostID: server.id.uuidString)
                            .opacity(server.status == .online ? 1 : 0.55)   // stale while reconnecting
                    }
                }
                .padding(.horizontal, style.s(Theme.hPadding))
                .padding(.top, style.s(10))
                .padding(.bottom, style.s(14))
            }
        }
    }
}

struct RemoteMetricsView: View {
    @Environment(\.panelStyle) private var style
    let s: RemoteSnapshot
    let hideDisks: Bool
    var hostID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: style.s(9)) {
            CompactMeter(icon: "cpu", title: "CPU", detail: nil,
                         value: Fmt.pct(s.cpu), fraction: s.cpu)
            CompactMeter(icon: "memorychip", title: "Memory",
                         detail: "\(Fmt.gb(s.memUsed))/\(Fmt.gb(s.memTotal)) GB",
                         value: Fmt.pct(s.memFraction), fraction: s.memFraction)
            if !hideDisks {
                ForEach(s.disks) { d in
                    CompactMeter(icon: d.mount == "/" ? "internaldrive" : "externaldrive",
                                 title: d.mount,
                                 detail: "\(Fmt.diskGB(Int64(clamping: d.free))) GB free",
                                 value: Fmt.pct(d.usedFraction), fraction: d.usedFraction)
                }
            }
            HStack(spacing: 6) {
                RateChip(arrow: "↓", rate: Fmt.rate(s.netIn))
                RateChip(arrow: "↑", rate: Fmt.rate(s.netOut))
            }
            if !hostID.isEmpty {
                HistoryChartCard(day: HistoryRecorder.shared.day(hostID),
                                 week: HistoryRecorder.shared.week(hostID))
            }
            let tags = tagList
            if !tags.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(tags) { tag in
                        TagChip(tag.text, warning: tag.warning)
                    }
                }
            }
        }
    }

    struct Tag: Identifiable {
        var text: String
        var warning: Bool
        var id: String { text }
    }

    /// Chips: uptime, docker, services, reboot / updates.
    private var tagList: [Tag] {
        var t: [Tag] = []
        if let up = s.uptime { t.append(Tag(text: "up " + Fmt.duration(up), warning: false)) }
        if let d = s.docker, d.total > 0 { t.append(Tag(text: "docker \(d.running)/\(d.total)", warning: false)) }
        for svc in s.services where !svc.state.isEmpty {
            t.append(Tag(text: svc.isActive ? "✓ \(svc.name)" : "✗ \(svc.name) \(svc.state)", warning: svc.isDown))
        }
        if s.rebootRequired == true { t.append(Tag(text: "reboot required", warning: true)) }
        if let n = s.pendingUpdates, n > 0 { t.append(Tag(text: "\(n) update\(n == 1 ? "" : "s")", warning: false)) }
        return t
    }
}

struct ServerHeader: View {
    @Environment(\.panelStyle) private var style
    let name: String
    let status: RemoteStatus
    let snapshot: RemoteSnapshot
    let collapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(style.palette.divider).frame(height: 0.5)
            HStack(spacing: 6) {
                StatusDot(dotKind)
                Text(name)
                    .font(style.font(12.5, rounded: false))
                    .foregroundColor(style.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if snapshot.os == "Darwin" {
                    Image(systemName: "applelogo")
                        .font(style.font(9, rounded: false))
                        .foregroundColor(style.palette.ink.opacity(0.5))
                }
                Spacer(minLength: 6)
                Text(rightText)
                    .font(style.detailFont)
                    .foregroundColor(warn ? style.palette.statusError : style.palette.ink.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, style.s(Theme.hPadding))
            .frame(height: style.s(30))
            Rectangle().fill(style.palette.divider).frame(height: 0.5)
        }
    }

    private var warn: Bool {
        collapsed && (!WidgetServer.warnings(for: snapshot).isEmpty || dotKind == .error)
    }

    private var rightText: String {
        let s = snapshot
        if collapsed {
            if case .error = status { return "offline" }
            guard s.hasData else { return "…" }
            var t = "CPU \(Fmt.pct(s.cpu))  MEM \(Fmt.pct(s.memFraction))"
            if let d = s.fullestDisk { t += "  DSK \(Fmt.pct(d.usedFraction))" }
            return t
        }
        guard s.load.count == 3 else { return "" }
        return String(format: "load %.2f %.2f %.2f", s.load[0], s.load[1], s.load[2])
    }

    private var dotKind: StatusDot.Kind {
        switch status {
        case .online: return .online
        case .connecting: return .connecting
        case .error: return .error
        }
    }
}
