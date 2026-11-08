import WidgetKit
import SwiftUI
import MacMonitorCore
import MacMonitorUI

// Desktop / Notification Center widgets for MacMonitor.
//  • "This Mac": CPU ring, memory, disk, battery or GPU, network — sampled by the widget itself.
//  • "Servers":  status of the SSH servers monitored by the app (read from the App Group container).
// WidgetKit refreshes widgets on its own budget (typically every few minutes); the app asks for
// an immediate reload whenever a server goes up/down or gets a new warning.

@main
struct MacMonitorWidgets: WidgetBundle {
    var body: some Widget {
        MacStatsWidget()
        ServersWidget()
    }
}

// MARK: - Entries & providers

struct MacEntry: TimelineEntry {
    let date: Date
    let data: MacWidgetData
    let payload: WidgetPayload?
}

struct ServersEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload?
}

enum LiveSample {
    /// Takes two readings one second apart so CPU and network are real rates, not averages since boot.
    static func mac() async -> MacWidgetData {
        let reader = LocalStatsReader()
        _ = reader.cpuLoad()
        _ = reader.networkRates()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let cpu = reader.cpuLoad() ?? 0
        let net = reader.networkRates()
        return MacWidgetData(hostName: LocalHost.name, cpu: cpu, memory: reader.memory(),
                             bootVolume: reader.volumes().first, netIn: net?.rx ?? 0, netOut: net?.tx ?? 0,
                             battery: reader.battery(), gpu: reader.gpuUtilization())
    }
}

struct MacProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacEntry {
        MacEntry(date: Date(), data: .sample, payload: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacEntry) -> Void) {
        if context.isPreview {
            completion(MacEntry(date: Date(), data: .sample,
                                payload: WidgetPayload(updated: Date(), hostName: "Mac", servers: WidgetServer.samples)))
            return
        }
        Task {
            let data = await LiveSample.mac()
            completion(MacEntry(date: Date(), data: data, payload: SharedStore.read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacEntry>) -> Void) {
        Task {
            let data = await LiveSample.mac()
            let entry = MacEntry(date: Date(), data: data, payload: SharedStore.read())
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
        }
    }
}

struct ServersProvider: TimelineProvider {
    func placeholder(in context: Context) -> ServersEntry {
        ServersEntry(date: Date(), payload: WidgetPayload(updated: Date(), hostName: "Mac", servers: WidgetServer.samples))
    }

    func getSnapshot(in context: Context, completion: @escaping (ServersEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(ServersEntry(date: Date(), payload: SharedStore.read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ServersEntry>) -> Void) {
        let entry = ServersEntry(date: Date(), payload: SharedStore.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }
}

// MARK: - Styling helpers

private struct WidgetChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let style = PanelStyle(palette: scheme == .dark ? .dark : .warm)
        let styled = content.environment(\.panelStyle, style)
        if #available(macOSApplicationExtension 14.0, *) {
            styled.containerBackground(for: .widget) {
                WidgetBackground().environment(\.panelStyle, style)
            }
        } else {
            styled
                .padding(14)
                .background(WidgetBackground().environment(\.panelStyle, style))
        }
    }
}

private extension WidgetFamily {
    var size: WidgetFamilySize {
        switch self {
        case .systemSmall: return .small
        case .systemLarge: return .large
        default: return .medium
        }
    }
}

// MARK: - Widgets

struct MacStatsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MacEntry

    var body: some View {
        MacWidgetView(data: entry.data, servers: entry.payload?.servers ?? [], size: family.size)
            .modifier(WidgetChrome())
            .widgetURL(URL(string: "macmonitor://panel"))
    }
}

struct MacStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacStatsWidget", provider: MacProvider()) { entry in
            MacStatsEntryView(entry: entry)
        }
        .configurationDisplayName("This Mac")
        .description("CPU, memory, disk, battery and network at a glance. The large size also lists your servers.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ServersEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ServersEntry

    var body: some View {
        ServersWidgetView(servers: entry.payload?.servers ?? [], size: family.size, updated: entry.payload?.updated)
            .modifier(WidgetChrome())
            .widgetURL(URL(string: "macmonitor://servers"))
    }
}

struct ServersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ServersWidget", provider: ServersProvider()) { entry in
            ServersEntryView(entry: entry)
        }
        .configurationDisplayName("Servers")
        .description("Status, CPU, memory and disk of the Linux and Mac servers MacMonitor watches over SSH.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
