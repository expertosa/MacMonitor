import SwiftUI

// MARK: - Palette (Tangerine-style warm light, plus a dark variant)

public struct Palette: Equatable {
    public var isDark: Bool
    public var ink: Color             // primary text
    public var label: Color           // section labels + icons
    public var accent: Color          // fills
    public var accentDeep: Color      // fills above 85%
    public var spark: Color           // CPU history bars
    public var track: Color
    public var divider: Color
    public var sliceStroke: Color
    public var sliceBase: Color
    public var ringBackdrop: Color
    public var centerCapsule: Color
    public var chipFill: Color
    public var well: Color
    public var highlight: Color
    public var gradientTop: Color
    public var gradientBottom: Color
    public var statusOnline = Color(hex: 0x2FB344)
    public var statusConnecting = Color(hex: 0xFF9500)
    public var statusError = Color(hex: 0xE5341D)

    public static let warm = Palette(
        isDark: false,
        ink: Color(hex: 0x271C0B),
        label: Color(hex: 0x5D0000),
        accent: Color(hex: 0xFF5200),
        accentDeep: Color(hex: 0xEB4500),
        spark: Color(hex: 0xFE6E21),
        track: Color(hex: 0xCB8979, opacity: 0.45),
        divider: Color(hex: 0xD78522, opacity: 0.4),
        sliceStroke: Color(hex: 0x5D6666, opacity: 0.22),
        sliceBase: Color.white.opacity(0.6),
        ringBackdrop: Color.white.opacity(0.18),
        centerCapsule: Color.white.opacity(0.72),
        chipFill: Color.black.opacity(0.07),
        well: Color.black.opacity(0.05),
        highlight: Color.white.opacity(0.35),
        gradientTop: Color(hex: 0xFFC24B, opacity: 0.85),
        gradientBottom: Color(hex: 0xFFBF8A, opacity: 0.75))

    public static let dark = Palette(
        isDark: true,
        ink: Color(hex: 0xF7EEE6),
        label: Color(hex: 0xFFB27A),
        accent: Color(hex: 0xFF7A2E),
        accentDeep: Color(hex: 0xFF5200),
        spark: Color(hex: 0xFF8A3D),
        track: Color.white.opacity(0.14),
        divider: Color.white.opacity(0.14),
        sliceStroke: Color.white.opacity(0.14),
        sliceBase: Color.white.opacity(0.10),
        ringBackdrop: Color.white.opacity(0.05),
        centerCapsule: Color.black.opacity(0.35),
        chipFill: Color.white.opacity(0.08),
        well: Color.white.opacity(0.05),
        highlight: Color.white.opacity(0.12),
        gradientTop: Color(hex: 0x3B2A1F, opacity: 0.80),
        gradientBottom: Color(hex: 0x1D1A1E, opacity: 0.85))
}

/// Palette + size scale, passed down the view tree through the environment.
public struct PanelStyle: Equatable {
    public var palette: Palette
    public var scale: CGFloat

    public init(palette: Palette = .warm, scale: CGFloat = 1) {
        self.palette = palette
        self.scale = scale
    }

    public func font(_ size: CGFloat, _ weight: Font.Weight = .semibold, rounded: Bool = true,
                     mono: Bool = false) -> Font {
        let f = Font.system(size: size * scale, weight: weight, design: rounded ? .rounded : .default)
        return mono ? f.monospacedDigit() : f
    }
    public var labelFont: Font { font(11) }
    public var valueFont: Font { font(12, mono: true) }
    public var detailFont: Font { font(10, .regular, mono: true) }
    public func s(_ v: CGFloat) -> CGFloat { v * scale }
}

private struct PanelStyleKey: EnvironmentKey {
    static let defaultValue = PanelStyle()
}

public extension EnvironmentValues {
    var panelStyle: PanelStyle {
        get { self[PanelStyleKey.self] }
        set { self[PanelStyleKey.self] = newValue }
    }
}

/// Layout constants (multiplied by PanelStyle.scale where relevant).
public enum Theme {
    public static let panelWidth: CGFloat = 250
    public static let cornerRadius: CGFloat = 20
    public static let hPadding: CGFloat = 16
    public static let sectionSpacing: CGFloat = 12
}

public extension Color {
    /// `Color(hex: 0xFF5200)` / `Color(hex: 0xFF5200, opacity: 0.5)`; sRGB, 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
