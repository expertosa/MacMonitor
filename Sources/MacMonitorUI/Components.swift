import SwiftUI
import MacMonitorCore

/// Warm gradient wash over the material, plus a hairline inner highlight.
public struct PanelBackground: View {
    @Environment(\.panelStyle) private var style
    var flatFill: Bool

    public init(flatFill: Bool = false) { self.flatFill = flatFill }

    public var body: some View {
        let p = style.palette
        ZStack {
            if flatFill {
                (p.isDark ? Color.black.opacity(0.45) : Color.white.opacity(0.35))
            }
            LinearGradient(colors: [p.gradientTop, p.gradientBottom], startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(p.highlight, lineWidth: 0.5)
        }
    }
}

public struct PanelHeader: View {
    @Environment(\.panelStyle) private var style
    let title: String
    let subtitle: String?

    public init(title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(style.font(13, rounded: false))
                    .foregroundColor(style.palette.ink)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(style.detailFont)
                        .foregroundColor(style.palette.ink.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, style.s(12))
            .frame(maxWidth: .infinity)
            .frame(height: style.s(34))
            Rectangle().fill(style.palette.divider).frame(height: 0.5)
        }
    }
}

/// Label (icon + title) on the left, monospaced value on the right.
public struct SectionRow: View {
    @Environment(\.panelStyle) private var style
    let icon: String
    let title: String
    let value: String?

    public init(icon: String, title: String, value: String?) {
        self.icon = icon; self.title = title; self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon)
                .font(style.font(10.5, rounded: false))
                .frame(width: style.s(15))
            Text(title)
                .font(style.labelFont)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let value {
                Text(value)
                    .font(style.valueFont)
                    .foregroundColor(style.palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .foregroundColor(style.palette.label)
    }
}

public struct MeterSection: View {
    @Environment(\.panelStyle) private var style
    let icon: String
    let title: String
    let value: String
    let detail: String
    let fraction: Double

    public init(icon: String, title: String, value: String, detail: String, fraction: Double) {
        self.icon = icon; self.title = title; self.value = value; self.detail = detail; self.fraction = fraction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.s(5)) {
            SectionRow(icon: icon, title: title, value: value)
            UsageBar(fraction: fraction)
            Text(detail)
                .font(style.detailFont)
                .foregroundColor(style.palette.ink.opacity(0.6))
                .lineLimit(1)
        }
    }
}

public struct UsageBar: View {
    @Environment(\.panelStyle) private var style
    let fraction: Double
    var height: CGFloat

    public init(fraction: Double, height: CGFloat = 6) { self.fraction = fraction; self.height = height }

    public var body: some View {
        let f = CGFloat(min(max(fraction, 0), 1))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(style.palette.track)
                Capsule().fill(fraction > 0.85 ? style.palette.accentDeep : style.palette.accent)
                    .frame(width: max(f > 0 ? height : 0, geo.size.width * f))
            }
        }
        .frame(height: height)
    }
}

public struct RateChip: View {
    @Environment(\.panelStyle) private var style
    let arrow: String
    let rate: String

    public init(arrow: String, rate: String) { self.arrow = arrow; self.rate = rate }

    public var body: some View {
        (Text(arrow).foregroundColor(style.palette.accentDeep) + Text(" " + rate).foregroundColor(style.palette.ink))
            .font(style.font(10.5, mono: true))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, style.s(9))
            .padding(.vertical, style.s(4))
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(style.palette.chipFill))
    }
}

/// Small rounded tag, e.g. "up 12d", "reboot required", "nginx failed".
public struct TagChip: View {
    @Environment(\.panelStyle) private var style
    let text: String
    let warning: Bool

    public init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }

    public var body: some View {
        Text(text)
            .font(style.font(9.5, warning ? .semibold : .medium, mono: true))
            .foregroundColor(warning ? .white : style.palette.ink.opacity(0.75))
            .lineLimit(1)
            .padding(.horizontal, style.s(6))
            .padding(.vertical, style.s(2))
            .background(Capsule().fill(warning ? style.palette.statusError.opacity(0.85) : style.palette.chipFill))
    }
}

/// One-line meter: icon + title, optional faded detail, value, then a thin bar.
public struct CompactMeter: View {
    @Environment(\.panelStyle) private var style
    let icon: String
    let title: String
    let detail: String?
    let value: String
    let fraction: Double

    public init(icon: String, title: String, detail: String?, value: String, fraction: Double) {
        self.icon = icon; self.title = title; self.detail = detail; self.value = value; self.fraction = fraction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.s(4)) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: icon)
                    .font(style.font(10.5, rounded: false))
                    .frame(width: style.s(15))
                Text(title)
                    .font(style.labelFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(style.detailFont)
                        .foregroundColor(style.palette.ink.opacity(0.6))
                        .lineLimit(1)
                        .layoutPriority(0.5)
                }
                Text(value)
                    .font(style.valueFont)
                    .foregroundColor(style.palette.ink)
                    .lineLimit(1)
                    .frame(minWidth: style.s(30), alignment: .trailing)
                    .layoutPriority(1)
            }
            .foregroundColor(style.palette.label)
            UsageBar(fraction: fraction, height: style.s(5))
        }
    }
}

public struct StatusDot: View {
    @Environment(\.panelStyle) private var style
    public enum Kind { case online, connecting, error }
    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public var body: some View {
        Circle()
            .fill(kind == .online ? style.palette.statusOnline
                  : kind == .connecting ? style.palette.statusConnecting : style.palette.statusError)
            .frame(width: style.s(7), height: style.s(7))
    }
}

// MARK: CPU ring (Tangerine-style wheel of rounded slices)

public struct CPURing: View {
    @Environment(\.panelStyle) private var style
    let load: Double
    var slices: Int
    var diameter: CGFloat
    var innerDiameter: CGFloat
    var caption: String

    public init(load: Double, slices: Int = 8, diameter: CGFloat = 110, innerDiameter: CGFloat = 46,
                caption: String = "CPU") {
        self.load = load; self.slices = slices; self.diameter = diameter
        self.innerDiameter = innerDiameter; self.caption = caption
    }

    public var body: some View {
        let p = style.palette
        let lit = min(max(load, 0), 1) * Double(slices)
        let k = diameter / 110
        ZStack {
            Circle()
                .fill(p.ringBackdrop)
                .frame(width: diameter + 8 * k, height: diameter + 8 * k)
            ForEach(0..<slices, id: \.self) { i in
                let shape = RingSlice(index: i, count: slices, innerRatio: innerDiameter / diameter,
                                      gap: 3 * k, corner: 6 * k)
                let f = min(max(lit - Double(i), 0), 1)          // 0 = unlit, 1 = fully lit
                ZStack {
                    shape.fill(p.sliceBase)
                    shape.fill(p.accent).opacity(f > 0 ? 0.3 + 0.7 * f : 0)
                    shape.stroke(p.sliceStroke, lineWidth: 0.75).opacity(1 - f)
                }
            }
            .frame(width: diameter, height: diameter)

            VStack(spacing: 0) {
                Text(Fmt.pct(load))
                    .font(.system(size: 13 * k, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(p.ink)
                Text(caption)
                    .font(.system(size: 8.5 * k, weight: .semibold, design: .rounded))
                    .foregroundColor(p.label.opacity(0.75))
            }
            .frame(width: 58 * k, height: 34 * k)
            .background(Capsule().fill(p.centerCapsule))
        }
        .frame(width: diameter + 8 * k, height: diameter + 8 * k)
    }
}

/// One annular sector of a ring with all four corners rounded.
/// Gaps between neighbours have constant width (`gap` points), like Tangerine's wheel.
public struct RingSlice: Shape {
    var index: Int
    var count: Int
    var innerRatio: CGFloat          // inner radius / outer radius
    var gap: CGFloat = 3
    var corner: CGFloat = 6

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        guard count > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rOut = min(rect.width, rect.height) / 2
        let rIn = rOut * innerRatio
        let h = gap / 2
        let k = min(corner, (rOut - rIn) / 2 - 0.5)
        guard rOut > rIn, k > 0 else { return p }

        let span = 2 * CGFloat.pi / CGFloat(count)
        // Slice 0 is centred at 12 o'clock; slices advance clockwise on screen (y-down).
        let a0 = -CGFloat.pi / 2 - span / 2 + CGFloat(index) * span
        let a1 = a0 + span

        // Fillet for the corner where the edge line at angle `a` meets a circle.
        // side = +1 for the start edge (slice lies toward increasing angle), -1 for the end edge.
        // outer = true: fillet inside the outer circle; false: fillet outside the inner circle.
        func fillet(_ a: CGFloat, side: CGFloat, outer: Bool) -> (center: CGPoint, onLine: CGPoint, onCircle: CGPoint) {
            let u = CGPoint(x: cos(a), y: sin(a))
            let n = CGPoint(x: -sin(a) * side, y: cos(a) * side)
            let d = h + k
            let dist = outer ? rOut - k : rIn + k
            let t = (max(dist * dist - d * d, 0)).squareRoot()
            let center = CGPoint(x: c.x + t * u.x + d * n.x, y: c.y + t * u.y + d * n.y)
            let onLine = CGPoint(x: c.x + t * u.x + h * n.x, y: c.y + t * u.y + h * n.y)
            let r = outer ? rOut : rIn
            let onCircle = CGPoint(x: c.x + (center.x - c.x) * r / dist,
                                   y: c.y + (center.y - c.y) * r / dist)
            return (center, onLine, onCircle)
        }
        func angle(_ pt: CGPoint, from o: CGPoint) -> CGFloat { atan2(pt.y - o.y, pt.x - o.x) }
        /// Signed sweep from a to b, normalised to (-pi, pi] (shortest way round).
        func shortest(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            var d = b - a
            while d > .pi { d -= 2 * .pi }
            while d <= -.pi { d += 2 * .pi }
            return d
        }
        func arc(_ center: CGPoint, _ radius: CGFloat, from: CGFloat, sweep: CGFloat) {
            p.addRelativeArc(center: center, radius: radius,
                             startAngle: .radians(Double(from)), delta: .radians(Double(sweep)))
        }

        let os = fillet(a0, side: 1, outer: true)
        let oe = fillet(a1, side: -1, outer: true)
        let ins = fillet(a0, side: 1, outer: false)
        let ine = fillet(a1, side: -1, outer: false)

        p.move(to: ins.onLine)
        p.addLine(to: os.onLine)
        var from = angle(os.onLine, from: os.center)
        arc(os.center, k, from: from, sweep: shortest(from, angle(os.onCircle, from: os.center)))
        from = angle(os.onCircle, from: c)
        var sweep = angle(oe.onCircle, from: c) - from
        while sweep <= 0 { sweep += 2 * .pi }
        arc(c, rOut, from: from, sweep: sweep)
        from = angle(oe.onCircle, from: oe.center)
        arc(oe.center, k, from: from, sweep: shortest(from, angle(oe.onLine, from: oe.center)))
        p.addLine(to: ine.onLine)
        from = angle(ine.onLine, from: ine.center)
        arc(ine.center, k, from: from, sweep: shortest(from, angle(ine.onCircle, from: ine.center)))
        from = angle(ine.onCircle, from: c)
        sweep = angle(ins.onCircle, from: c) - from
        while sweep >= 0 { sweep -= 2 * .pi }
        arc(c, rIn, from: from, sweep: sweep)
        from = angle(ins.onCircle, from: ins.center)
        arc(ins.center, k, from: from, sweep: shortest(from, angle(ins.onLine, from: ins.center)))
        p.closeSubpath()
        return p
    }
}

/// CPU history as vertical bars in a recessed well.
public struct HistoryBars: View {
    @Environment(\.panelStyle) private var style
    let values: [Double]

    public init(values: [Double]) { self.values = values }

    public var body: some View {
        BarsShape(values: values)
            .fill(style.palette.spark)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.palette.well))
    }
}

public struct BarsShape: Shape {
    let values: [Double]

    public init(values: [Double]) { self.values = values }

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return p }
        let step = rect.width / CGFloat(values.count)
        let barW = max(1, step - 1.2)
        let r = min(barW / 2, 1.2)
        for (i, v) in values.enumerated() {
            let hgt = max(1.5, CGFloat(min(max(v, 0), 1)) * rect.height)
            let bar = CGRect(x: rect.minX + CGFloat(i) * step + (step - barW) / 2,
                             y: rect.maxY - hgt, width: barW, height: hgt)
            p.addRoundedRect(in: bar, cornerSize: CGSize(width: r, height: r))
        }
        return p
    }
}
