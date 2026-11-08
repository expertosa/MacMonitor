import Foundation

/// Formatting helpers (no formatter objects, cheap enough to call every tick).
public enum Fmt {
    public static func gb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_073_741_824) }
    public static func diskGB(_ bytes: Int64) -> String { String(format: "%.0f", Double(bytes) / 1_000_000_000) }
    public static func pct(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }

    public static func rate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        switch b {
        case ..<1_000:          return String(format: "%.0f B/s", b)
        case ..<1_000_000:      return String(format: "%.1f KB/s", b / 1_000)
        case ..<1_000_000_000:  return String(format: "%.1f MB/s", b / 1_000_000)
        default:                return String(format: "%.2f GB/s", b / 1_000_000_000)
        }
    }

    /// Short rate for the menu bar: "1.2M", "830K", "12B".
    public static func shortRate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        switch b {
        case ..<1_000:          return String(format: "%.0fB", b)
        case ..<1_000_000:      return String(format: "%.0fK", b / 1_000)
        case ..<1_000_000_000:  return String(format: "%.1fM", b / 1_000_000)
        default:                return String(format: "%.1fG", b / 1_000_000_000)
        }
    }

    /// "3d 4h", "5h 12m", "12m", "40s".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    public static func temp(_ celsius: Double) -> String { String(format: "%.0f°", celsius) }
    public static func watts(_ w: Double) -> String { String(format: w < 10 ? "%.1f W" : "%.0f W", w) }
}
