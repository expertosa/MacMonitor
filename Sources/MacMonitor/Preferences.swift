import Foundation
import Combine
import MacMonitorCore

enum MenuBarItem: String, CaseIterable, Identifiable {
    case cpu, ram, gpu, network, battery, temperature
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .ram: return "Memory"
        case .gpu: return "GPU"
        case .network: return "Network"
        case .battery: return "Battery"
        case .temperature: return "CPU temperature"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case text, graph
    var id: String { rawValue }
    var label: String { self == .text ? "Text" : "CPU graph + text" }
}

enum PanelTheme: String, CaseIterable, Identifiable {
    case warm, dark, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .warm: return "Warm (light)"
        case .dark: return "Dark"
        case .auto: return "Match system"
        }
    }
}

enum PanelSize: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .compact: return 0.88
        case .regular: return 1
        case .large: return 1.15
        }
    }
}

enum PanelCorner: String, CaseIterable, Identifiable {
    case custom, topRight, topLeft, bottomRight, bottomLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .custom: return "Where I drag it"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        }
    }
}

enum PanelSection: String, CaseIterable, Identifiable {
    case cpuHistory, memory, memoryDetail, gpu, disks, network, battery, sensors, processes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpuHistory: return "CPU history"
        case .memory: return "Memory"
        case .memoryDetail: return "Memory pressure & swap"
        case .gpu: return "GPU"
        case .disks: return "Disks"
        case .network: return "Network"
        case .battery: return "Battery & power"
        case .sensors: return "Temperatures & fans"
        case .processes: return "Top processes"
        }
    }
    /// Sections that only exist in the direct (non-sandboxed) edition.
    var directOnly: Bool { self == .sensors || self == .processes }
    static let defaults: Set<PanelSection> = [.cpuHistory, .memory, .memoryDetail, .gpu, .disks, .network, .battery]
}

/// All user settings, backed by UserDefaults. Every change publishes objectWillChange once.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    private enum Key {
        static let menuItems = "menuBarItems", menuStyle = "menuBarStyle", interval = "updateInterval"
        static let theme = "panelTheme", size = "panelSize", corner = "panelCorner", sections = "panelSections"
        static let alerts = "alertSettings", checkUpdates = "checkForUpdates"
    }

    @Published var menuBarItems: Set<MenuBarItem> { didSet { d.set(menuBarItems.map(\.rawValue).sorted(), forKey: Key.menuItems) } }
    @Published var menuBarStyle: MenuBarStyle { didSet { d.set(menuBarStyle.rawValue, forKey: Key.menuStyle) } }
    /// Seconds between local samples (1, 2 or 5).
    @Published var updateInterval: Double { didSet { d.set(updateInterval, forKey: Key.interval) } }
    @Published var theme: PanelTheme { didSet { d.set(theme.rawValue, forKey: Key.theme) } }
    @Published var size: PanelSize { didSet { d.set(size.rawValue, forKey: Key.size) } }
    @Published var corner: PanelCorner { didSet { d.set(corner.rawValue, forKey: Key.corner) } }
    @Published var sections: Set<PanelSection> { didSet { d.set(sections.map(\.rawValue).sorted(), forKey: Key.sections) } }
    @Published var alerts: AlertSettings {
        didSet { if let data = try? JSONEncoder().encode(alerts) { d.set(data, forKey: Key.alerts) } }
    }
    @Published var checkForUpdates: Bool { didSet { d.set(checkForUpdates, forKey: Key.checkUpdates) } }

    private init() {
        let items = (d.stringArray(forKey: Key.menuItems) ?? ["cpu", "ram"]).compactMap(MenuBarItem.init)
        menuBarItems = Set(items)
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: Key.menuStyle) ?? "") ?? .text
        let interval = d.double(forKey: Key.interval)
        updateInterval = [1.0, 2.0, 5.0].contains(interval) ? interval : 1
        theme = PanelTheme(rawValue: d.string(forKey: Key.theme) ?? "") ?? .warm
        size = PanelSize(rawValue: d.string(forKey: Key.size) ?? "") ?? .regular
        corner = PanelCorner(rawValue: d.string(forKey: Key.corner) ?? "") ?? .custom
        if let list = d.stringArray(forKey: Key.sections) {
            sections = Set(list.compactMap(PanelSection.init))
        } else {
            sections = PanelSection.defaults
        }
        if let data = d.data(forKey: Key.alerts), let a = try? JSONDecoder().decode(AlertSettings.self, from: data) {
            alerts = a
        } else {
            alerts = AlertSettings()
        }
        checkForUpdates = d.object(forKey: Key.checkUpdates) as? Bool ?? true
    }

    func shows(_ s: PanelSection) -> Bool {
        #if APPSTORE
        if s.directOnly { return false }
        #endif
        return sections.contains(s)
    }
}
