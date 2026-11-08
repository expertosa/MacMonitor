import AppKit
import MacMonitorCore

/// Builds the status item title (and optional CPU sparkline image) from a snapshot.
@MainActor
enum MenuBarRenderer {
    static func title(for s: Snapshot, items: Set<MenuBarItem>) -> String {
        var parts: [String] = []
        for item in MenuBarItem.allCases where items.contains(item) {
            switch item {
            case .cpu: parts.append(String(format: "CPU %2.0f%%", s.cpu * 100))
            case .ram: parts.append(String(format: "RAM %2.0f%%", s.memFraction * 100))
            case .gpu: if let g = s.gpu { parts.append(String(format: "GPU %2.0f%%", g * 100)) }
            case .network: parts.append("↓\(Fmt.shortRate(s.netIn)) ↑\(Fmt.shortRate(s.netOut))")
            case .battery:
                if let b = s.battery { parts.append(String(format: "%@%.0f%%", b.charging ? "⚡︎" : "BAT ", b.percent)) }
            case .temperature:
                #if !APPSTORE
                if let t = s.sensors.cpuTemp { parts.append(Fmt.temp(t)) }
                #endif
            }
        }
        return parts.isEmpty ? "MM" : parts.joined(separator: "  ")
    }

    /// 30-sample CPU history as a template image (adapts to light/dark menu bars).
    static func sparkline(_ values: [Double]) -> NSImage {
        let samples = Array(values.suffix(30))
        let size = NSSize(width: CGFloat(samples.count) * 1.5 + 2, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5), xRadius: 2, yRadius: 2).fill()
            NSColor.black.setFill()
            for (i, v) in samples.enumerated() {
                let h = max(1, CGFloat(min(max(v, 0), 1)) * (rect.height - 5))
                NSRect(x: 1 + CGFloat(i) * 1.5, y: 2.5, width: 1.1, height: h).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
