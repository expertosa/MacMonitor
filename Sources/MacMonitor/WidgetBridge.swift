import Foundation
import WidgetKit
import MacMonitorCore

/// Publishes server state to the App Group container for the widget extension and asks
/// WidgetKit to refresh when something important changes. Does nothing unless the app was
/// built with the widget (Xcode build), so the plain SwiftPM build never touches the
/// group container (which would trigger a macOS privacy prompt for unsigned apps).
@MainActor
final class WidgetBridge {
    private var lastWrite = Date.distantPast
    private var lastReload = Date.distantPast
    private var lastSignature = ""

    static var hasWidget: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("MacMonitorWidget.appex").path)
    }

    private let enabled = WidgetBridge.hasWidget

    func update(servers: [WidgetServer], force: Bool = false) {
        guard enabled else { return }
        let now = Date()
        // Status changes (online/offline, new warnings) refresh widgets right away.
        let signature = servers.map { "\($0.id)\($0.state.rawValue)\($0.warnings.joined())" }.joined()
        let important = signature != lastSignature
        guard force || important || now.timeIntervalSince(lastWrite) >= 60 else { return }
        SharedStore.write(WidgetPayload(updated: now, hostName: LocalHost.name, servers: servers))
        lastWrite = now
        lastSignature = signature
        if force || important || now.timeIntervalSince(lastReload) >= 300 {
            WidgetCenter.shared.reloadAllTimelines()
            lastReload = now
        }
    }
}

#if !APPSTORE
extension RemoteSampler {
    var widgetServer: WidgetServer {
        let s = snapshot
        let state: WidgetServer.State
        var message: String?
        switch status {
        case .online: state = .online
        case .connecting: state = .connecting
        case .error(let m): state = .error; message = m
        }
        let disk = s.fullestDisk
        return WidgetServer(id: id, name: config.name, state: state, message: message,
                            cpu: s.hasData ? s.cpu : nil, memFraction: s.hasData ? s.memFraction : nil,
                            diskFraction: disk?.usedFraction, diskMount: disk?.mount,
                            load1: s.load.first, warnings: WidgetServer.warnings(for: s))
    }
}
#endif
