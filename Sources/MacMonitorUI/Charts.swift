import SwiftUI
import MacMonitorCore

/// Line chart for one host's downsampled history. Hidden until a range has two buckets,
/// so a fresh launch does not change the panel height.
public struct HistoryChartCard: View {
    @Environment(\.panelStyle) private var style
    let day: [HistoryBucket]
    let week: [HistoryBucket]
    @State private var range: HistoryRange = .day
    @State private var metric: Metric = .cpu

    public enum Metric: String, CaseIterable, Identifiable {
        case cpu, memory, disk, network
        public var id: String { rawValue }
        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .disk: return "Disk"
            case .network: return "Network"
            }
        }
    }

    public init(day: [HistoryBucket], week: [HistoryBucket]) {
        self.day = day
        self.week = week
    }

    public var body: some View {
        let buckets = active
        if buckets.count >= 2 {
            VStack(alignment: .leading, spacing: style.s(6)) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(style.font(10.5, rounded: false))
                        .foregroundColor(style.palette.label)
                    Text("History")
                        .font(style.labelFont)
                        .foregroundColor(style.palette.label)
                    Spacer(minLength: 4)
                    rangeButton(.day, title: "24h")
                    rangeButton(.week, title: "7d")
                }
                HStack(spacing: 4) {
                    ForEach(Metric.allCases) { item in
                        metricButton(item)
                    }
                }
                chart(buckets)
                    .frame(height: style.s(64))
                HStack {
                    Text(label(buckets.first?.start))
                    Spacer(minLength: 4)
                    Text(label(buckets.last?.start))
                }
                .font(style.font(9, rounded: false))
                .foregroundColor(style.palette.ink.opacity(0.45))
            }
        }
    }

    private var active: [HistoryBucket] {
        let preferred = range == .day ? day : week
        if preferred.count >= 2 { return preferred }
        return day.count >= 2 ? day : week
    }

    private func rangeButton(_ value: HistoryRange, title: String) -> some View {
        let on = range == value && (value == .day ? day.count >= 2 : week.count >= 2)
        return Text(title)
            .font(style.font(9, rounded: false))
            .foregroundColor(on ? style.palette.ink : style.palette.ink.opacity(0.45))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(on ? style.palette.chipFill : Color.clear))
            .onTapGesture { range = value }
    }

    private func metricButton(_ item: Metric) -> some View {
        let on = metric == item
        return Text(item.label)
            .font(style.font(9, rounded: false))
            .foregroundColor(on ? Color.white : style.palette.ink.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(on ? style.palette.accent : style.palette.chipFill))
            .onTapGesture { metric = item }
    }

    @ViewBuilder
    private func chart(_ buckets: [HistoryBucket]) -> some View {
        let primary = buckets.map { value($0, metric) }
        let secondary: [Double]? = metric == .network ? buckets.map(\.netOut) : nil
        HistoryLine(primary: primary, secondary: secondary, color: style.palette.accent,
                    second: style.palette.spark)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.palette.well))
    }

    private func value(_ bucket: HistoryBucket, _ metric: Metric) -> Double {
        switch metric {
        case .cpu: return bucket.cpu
        case .memory: return bucket.memory
        case .disk: return bucket.disk
        case .network: return bucket.netIn
        }
    }

    private func label(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = range == .day ? "HH:mm" : "MMM d HH:mm"
        return f.string(from: date)
    }
}

struct HistoryLine: View {
    let primary: [Double]
    let secondary: [Double]?
    let color: Color
    let second: Color

    var body: some View {
        Canvas { context, size in
            func draw(_ values: [Double], _ stroke: Color, scale: Double) {
                guard values.count >= 2, size.width > 1, size.height > 1, scale > 0 else { return }
                var path = Path()
                for (i, raw) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = size.height * (1 - CGFloat(min(max(raw / scale, 0), 1)))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(stroke), lineWidth: 1.5)
            }
            let peak = max(primary.max() ?? 0, secondary?.max() ?? 0, 0.0001)
            let fraction = (primary.max() ?? 0) <= 1.5 && secondary == nil
            draw(primary, color, scale: fraction ? 1 : peak)
            if let secondary { draw(secondary, second, scale: peak) }
        }
    }
}
