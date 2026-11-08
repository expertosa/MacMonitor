import AppKit
import SwiftUI
import MacMonitorCore
import MacMonitorUI

/// Debug / screenshot helpers:
///   MM_SNAPSHOT=/tmp/panel.png        render the desktop panel after ~3 s, then quit
///   MM_SNAPSHOT_THEME=dark            (with MM_SNAPSHOT) force the dark palette
///   MM_WIDGET_SNAPSHOT=/tmp/dir       render every widget size with sample data, then quit
@MainActor
enum SnapshotExporter {
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return !(env["MM_SNAPSHOT"] ?? "").isEmpty || !(env["MM_WIDGET_SNAPSHOT"] ?? "").isEmpty
    }

    #if APPSTORE
    static func scheduleIfRequested(sampler: Sampler, prefs: Preferences) {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MM_WIDGET_SNAPSHOT"], !dir.isEmpty { renderWidgets(to: dir); NSApp.terminate(nil); return }
        guard let path = env["MM_SNAPSHOT"], !path.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let CPU / network samples settle
            renderPanel(MonitorView(sampler: sampler, prefs: prefs, snapshotMode: true), to: path)
            NSApp.terminate(nil)
        }
    }
    #else
    static func scheduleIfRequested(sampler: Sampler, remotes: RemoteManager, prefs: Preferences) {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MM_WIDGET_SNAPSHOT"], !dir.isEmpty { renderWidgets(to: dir); NSApp.terminate(nil); return }
        guard let path = env["MM_SNAPSHOT"], !path.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let CPU / network samples settle
            renderPanel(MonitorView(sampler: sampler, remotes: remotes, prefs: prefs, snapshotMode: true), to: path)
            NSApp.terminate(nil)
        }
    }
    #endif

    private static var wallpaper: some View {
        LinearGradient(colors: [Color(hex: 0xF78F41), Color(hex: 0xFF604F), Color(hex: 0xA191C5)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func renderPanel(_ view: MonitorView, to path: String) {
        let preview = view
            .fixedSize()
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
            .padding(32)
            .background(wallpaper)
        write(preview, to: path)
    }

    /// Renders the widget views at the standard macOS widget sizes with sample data.
    static func renderWidgets(to dir: String) {
        let sizes: [(String, WidgetFamilySize, CGSize)] = [
            ("small", .small, CGSize(width: 170, height: 170)),
            ("medium", .medium, CGSize(width: 364, height: 170)),
            ("large", .large, CGSize(width: 364, height: 382)),
        ]
        for dark in [false, true] {
            let style = PanelStyle(palette: dark ? .dark : .warm)
            for (name, family, size) in sizes {
                let mac = MacWidgetView(data: .sample, servers: WidgetServer.samples, size: family)
                write(card(mac, size: size, style: style),
                      to: "\(dir)/widget-mac-\(name)\(dark ? "-dark" : "").png")
                if family != .small {
                    let srv = ServersWidgetView(servers: WidgetServer.samples, size: family,
                                                updated: Date().addingTimeInterval(-120))
                    write(card(srv, size: size, style: style),
                          to: "\(dir)/widget-servers-\(name)\(dark ? "-dark" : "").png")
                }
            }
        }
    }

    private static func card<V: View>(_ content: V, size: CGSize, style: PanelStyle) -> some View {
        content
            .padding(14)
            .frame(width: size.width, height: size.height)
            .background(WidgetBackground())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.panelStyle, style)
            .environment(\.colorScheme, style.palette.isDark ? .dark : .light)
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
            .padding(24)
            .background(wallpaper)
    }

    private static func write<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: render failed for \(path)\n".utf8))
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encoding failed\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
        }
    }
}
