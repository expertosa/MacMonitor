import AppKit
import SwiftUI
import Combine
import MacMonitorCore
import MacMonitorUI

/// Borderless, non-activating panel that lives on the desktop layer behind normal windows.
final class DesktopPanel: NSPanel {
    private let dragView = DragOverlayView()
    private static let originKey = "panelOrigin"
    private var hosting: NSHostingView<MonitorView>?
    private let effect = NSVisualEffectView()
    private var subs: Set<AnyCancellable> = []
    private let sampler: Sampler
    private let prefs: Preferences
    #if !APPSTORE
    private let remotes: RemoteManager
    #endif
    private var lastLayoutKey: [Int] = []
    private var movingProgrammatically = false

    #if APPSTORE
    init(sampler: Sampler, prefs: Preferences) {
        self.sampler = sampler
        self.prefs = prefs
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setUp()
    }
    #else
    init(sampler: Sampler, remotes: RemoteManager, prefs: Preferences) {
        self.sampler = sampler
        self.remotes = remotes
        self.prefs = prefs
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setUp()
    }
    #endif

    private func setUp() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = false     // dragging handled by DragOverlayView
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let radius = Theme.cornerRadius
        effect.blendingMode = .behindWindow
        effect.state = .active                   // stay vibrant even though the app is never active
        effect.maskImage = DesktopPanel.roundedMask(radius: radius)
        applyAppearance()

        #if APPSTORE
        let hosting = NSHostingView(rootView: MonitorView(sampler: sampler, prefs: prefs))
        #else
        let hosting = NSHostingView(rootView: MonitorView(sampler: sampler, remotes: remotes, prefs: prefs))
        #endif
        self.hosting = hosting
        lastLayoutKey = currentLayoutKey()
        let size = Self.fittingSize(for: hosting, scale: prefs.size.scale)
        setContentSize(size)

        effect.frame = NSRect(origin: .zero, size: size)
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        dragView.frame = effect.bounds
        dragView.autoresizingMask = [.width, .height]
        dragView.cornerRadius = radius
        effect.addSubview(hosting)
        effect.addSubview(dragView)              // on top: receives mouse events when unlocked
        contentView = effect

        restoreOrigin()

        // Re-measure (keeping the anchored edge fixed) whenever something can change the height:
        // sections appearing/disappearing, settings, servers. Each trigger only compares one
        // combined layout key, so the per-tick cost is negligible.
        var triggers: [AnyPublisher<Void, Never>] = [
            sampler.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            prefs.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        #if !APPSTORE
        triggers.append(remotes.$servers.map { _ in () }.eraseToAnyPublisher())
        triggers.append(remotes.layoutChanged.eraseToAnyPublisher())
        #endif
        Publishers.MergeMany(triggers)
            .sink { [weak self] _ in
                // @Published fires in willSet: look at the new state on the next main-queue turn.
                DispatchQueue.main.async { self?.layoutMaybeChanged() }
            }
            .store(in: &subs)

        prefs.$corner.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyCorner() } }
            .store(in: &subs)
        Publishers.Merge(prefs.$theme.map { _ in () }, SystemAppearance.shared.$isDark.map { _ in () })
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }
            .store(in: &subs)

        NotificationCenter.default.addObserver(self, selector: #selector(didMove(_:)),
                                               name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func applyAppearance() {
        let dark = prefs.effectiveDark
        let app = NSAppearance(named: dark ? .darkAqua : .aqua)
        appearance = app
        effect.appearance = app
        effect.material = dark ? .hudWindow : .popover
    }

    private static func fittingSize(for hosting: NSView, scale: CGFloat) -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        return NSSize(width: max(fit.width, Theme.panelWidth * scale), height: max(fit.height, 120))
    }

    private func currentLayoutKey() -> [Int] {
        let s = sampler.snapshot
        var key = [s.volumes.count, s.battery == nil ? 0 : 1, s.gpu == nil ? 0 : 1,
                   Int(prefs.size.scale * 100), prefs.sections.count,
                   prefs.sections.map(\.rawValue).sorted().joined().hashValue]
        #if !APPSTORE
        key += [s.sensors.isEmpty ? 0 : 1, s.processes.count]
        key += remotes.layoutKey
        #endif
        return key
    }

    private func layoutMaybeChanged() {
        let key = currentLayoutKey()
        guard key != lastLayoutKey else { return }
        lastLayoutKey = key
        resize()
        // SwiftUI may apply the new content a runloop turn later; re-measure once shortly after.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.resize()
        }
    }

    private var anchoredToBottom: Bool { prefs.corner == .bottomLeft || prefs.corner == .bottomRight }

    private func resize() {
        guard let hosting else { return }
        let size = Self.fittingSize(for: hosting, scale: prefs.size.scale)
        guard size != frame.size else { return }
        let y = anchoredToBottom ? frame.minY : frame.maxY - size.height
        let x = (prefs.corner == .topRight || prefs.corner == .bottomRight) ? frame.maxX - size.width : frame.minX
        movingProgrammatically = true
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        movingProgrammatically = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var locked: Bool = true {
        didSet {
            ignoresMouseEvents = locked          // click-through when locked
            dragView.isHidden = locked
        }
    }

    // MARK: Position

    @objc private func didMove(_ note: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
        // A drag by the user switches to free positioning.
        if !movingProgrammatically, !locked, prefs.corner != .custom {
            prefs.corner = .custom
        }
    }

    @objc private func screensChanged() { if prefs.corner != .custom { applyCorner() } }

    /// Snaps the panel to the configured screen corner (no-op for .custom).
    func applyCorner() {
        guard prefs.corner != .custom, let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let m: CGFloat = 20
        let x: CGFloat, y: CGFloat
        switch prefs.corner {
        case .topLeft: x = vf.minX + m; y = vf.maxY - frame.height - m
        case .bottomLeft: x = vf.minX + m; y = vf.minY + m
        case .bottomRight: x = vf.maxX - frame.width - m; y = vf.minY + m
        default: x = vf.maxX - frame.width - m; y = vf.maxY - frame.height - m
        }
        movingProgrammatically = true
        setFrameOrigin(NSPoint(x: x, y: y))
        movingProgrammatically = false
    }

    private func restoreOrigin() {
        if prefs.corner != .custom { applyCorner(); return }
        if let str = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(str)
            let rect = NSRect(origin: origin, size: frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                setFrameOrigin(origin)
                return
            }
        }
        // Default: top-right corner of the main screen
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            setFrameOrigin(NSPoint(x: vf.maxX - frame.width - 20, y: vf.maxY - frame.height - 20))
        }
    }

    /// 9-slice mask matching SwiftUI's continuous ("squircle") rounded rectangle.
    /// A continuous corner extends ~1.53x the radius along each edge, so the cap insets are larger.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let inset = ceil(radius * 1.6)
        let edge = inset * 2 + 1
        let rect = CGRect(x: 0, y: 0, width: edge, height: edge)
        let continuous = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(continuous)
            ctx.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }
}

/// Transparent view covering the panel while unlocked: drags the window and shows a hint border.
final class DragOverlayView: NSView {
    var cornerRadius: CGFloat = Theme.cornerRadius

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
        path.lineWidth = 2
        let dash: [CGFloat] = [6, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }
}
