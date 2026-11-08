// Remote (SSH) server monitoring. The direct edition can use /usr/bin/ssh; both editions can
// use the built-in client (the only option inside the App Store sandbox). See Transports.swift.
import Foundation
import Combine
import MacMonitorCore

enum RemoteStatus: Equatable {
    case connecting
    case online
    case error(String)
}

/// Monitors one server through a single long-lived SSH session running a sh loop.
/// Nothing is installed on the server. Stdout is parsed off the main thread; results are
/// published on the main thread at most once per remote block (every 2 s).
@MainActor
final class RemoteSampler: ObservableObject, Identifiable {
    nonisolated let id: UUID
    @Published private(set) var config: ServerConfig
    /// Last time a sample arrived (for "updated … ago").
    private(set) var lastData: Date?

    @Published private(set) var snapshot = RemoteSnapshot()
    @Published private(set) var status: RemoteStatus = .connecting

    /// Called after a change that can alter the section's height (status, disk count, error text).
    var onLayoutChange: (() -> Void)?

    private var transport: RemoteTransport?
    private var parser = RemoteStreamParser()
    private var metrics = RemoteMetrics()
    private var watchdog: Task<Void, Never>?
    /// Online sessions that deliver nothing for this long are restarted (the built-in client has
    /// no ServerAlive keepalives, and a silent remote loop means something is wrong anyway).
    private static let stallTimeout: TimeInterval = 30
    private var generation = 0            // invalidates callbacks from older processes
    private var attempt = 0               // index into retryDelays
    private var stopped = false
    private var onlineThisRun = false
    private var retryTask: Task<Void, Never>?
    private static let retryDelays: [TimeInterval] = [5, 10, 30, 60]

    init(config: ServerConfig) {
        self.id = config.id
        self.config = config
    }

    /// Demo instance for MM_SNAPSHOT previews: never launches ssh.
    init(demo config: ServerConfig, snapshot: RemoteSnapshot) {
        self.id = config.id
        self.config = config
        self.snapshot = snapshot
        self.status = .online
        self.stopped = true
        self.lastData = Date()
    }

    /// Key that changes whenever this server's section changes height.
    var layoutKey: [Int] {
        let s: Int
        var errHash = 0
        switch status {
        case .connecting: s = 0
        case .online: s = 1
        case .error(let msg): s = 2; errHash = msg.count / 30   // ~ line-wrap bucket
        }
        return [s, errHash, snapshot.hasData ? 1 : 0, config.hideDisks ? 0 : snapshot.disks.count,
                config.collapsed ? 1 : 0, extrasKey]
    }

    /// Changes when the extras row (uptime, docker, services, warnings) changes size.
    private var extrasKey: Int {
        let s = snapshot
        return s.services.count * 7 + WidgetServer.warnings(for: s).count * 3
            + (s.docker == nil ? 0 : 1) + (s.uptime == nil ? 0 : 2)
    }

    /// Display-only changes (name, collapsed, hide disks) apply without reconnecting.
    func updateDisplay(_ new: ServerConfig) {
        guard new.id == id else { return }
        let oldKey = layoutKey
        config = new
        if layoutKey != oldKey { onLayoutChange?() }
    }

    // MARK: Lifecycle

    func start() {
        guard transport == nil else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        generation &+= 1
        teardown(terminate: true)
    }

    /// Reconnect immediately (menu item), resetting the backoff.
    func reconnect() {
        stop()
        attempt = 0
        stopped = false
        setStatus(.connecting)
        launch()
    }

    private func launch() {
        guard !stopped else { return }
        generation &+= 1
        let gen = generation
        onlineThisRun = false
        metrics.resetBaselines()
        let parser = RemoteStreamParser()
        self.parser = parser
        setStatus(.connecting)

        switch TransportFactory.make(for: config) {
        case .failure(let e):
            setStatus(.error(e.message))
            return                              // configuration problem: retrying won't help
        case .success(let t):
            transport = t
            t.start(onStdout: { [weak self] data in
                let result = parser.feed(data)
                guard result.hostname != nil || result.os != nil || !result.samples.isEmpty else { return }
                Task { @MainActor in self?.receive(result, generation: gen) }
            }, onExit: { [weak self] message in
                Task { @MainActor in self?.transportExited(message, generation: gen) }
            })
            startWatchdog(generation: gen)
        }
    }

    private func teardown(terminate: Bool) {
        watchdog?.cancel()
        watchdog = nil
        guard let t = transport else { return }
        transport = nil
        if terminate { t.stop() }
    }

    private func startWatchdog(generation gen: Int) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled, gen == self.generation, !self.stopped else { return }
                if self.status == .online, let last = self.lastData,
                   Date().timeIntervalSince(last) > Self.stallTimeout {
                    self.generation &+= 1
                    self.teardown(terminate: true)
                    self.setStatus(.error("No data for \(Int(Self.stallTimeout)) s"))
                    self.scheduleRetry()
                    return
                }
            }
        }
    }

    // MARK: Callbacks (main thread)

    private func receive(_ result: RemoteStreamParser.Output, generation gen: Int) {
        guard gen == generation, !stopped else { return }
        var s = snapshot
        if let h = result.hostname { s.hostname = h }
        if let os = result.os { s.os = os }
        for raw in result.samples { metrics.apply(raw, to: &s) }
        let oldKey = layoutKey
        if s != snapshot { snapshot = s }
        if !result.samples.isEmpty {
            onlineThisRun = true
            attempt = 0
            lastData = Date()
            setStatus(.online)
        }
        if layoutKey != oldKey { onLayoutChange?() }
    }

    private func transportExited(_ message: String, generation gen: Int) {
        guard gen == generation else { return }
        teardown(terminate: false)
        guard !stopped else { return }
        if onlineThisRun { attempt = 0 }
        setStatus(.error(message.isEmpty ? "Connection closed" : message))
        // A changed host key needs the user's decision; don't hammer the server.
        if message.hasPrefix("Host key changed") { return }
        scheduleRetry()
    }

    /// True when the last error was a host key mismatch (offers "Trust New Host Key").
    var hostKeyMismatch: Bool {
        if case .error(let m) = status { return m.hasPrefix("Host key changed") }
        return false
    }

    private func scheduleRetry() {
        guard !stopped else { return }
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        if case .error(let msg) = status {
            setStatus(.error("\(msg) · retry in \(Int(delay)) s"))
        }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.retryTask = nil
            self.launch()
        }
    }

    private func setStatus(_ new: RemoteStatus) {
        guard new != status else { return }
        let oldKey = layoutKey
        status = new
        if layoutKey != oldKey { onLayoutChange?() }
    }
}

// MARK: - Server list + persistence

@MainActor
final class RemoteManager: ObservableObject {
    private static let defaultsKey = "remoteServers"

    @Published private(set) var servers: [RemoteSampler] = []
    /// Fires (on the main thread) whenever any server section may have changed height.
    let layoutChanged = PassthroughSubject<Void, Never>()
    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            servers = [Self.demoServer()]
        } else {
            servers = Self.load().map { self.makeSampler($0) }
            servers.forEach { $0.start() }
        }
    }

    var configs: [ServerConfig] { servers.map(\.config) }

    /// Combined height key of all server sections.
    var layoutKey: [Int] { [servers.count] + servers.flatMap(\.layoutKey) }

    func add(_ config: ServerConfig) {
        let s = makeSampler(config)
        servers.append(s)
        save()
        s.start()
        notifyLayout()
    }

    func remove(id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].stop()
        if !demo {
            ServerSecrets.deleteAll(id)
            KnownHostKeys.set(nil, id)
        }
        servers.remove(at: i)
        save()
        notifyLayout()
    }

    func reconnect(id: UUID) { servers.first(where: { $0.id == id })?.reconnect() }

    func server(id: UUID) -> RemoteSampler? { servers.first { $0.id == id } }

    /// Forget the stored host key (server reinstalled) and reconnect, accepting the new key.
    func trustNewHostKey(id: UUID) {
        KnownHostKeys.set(nil, id)
        reconnect(id: id)
    }

    /// Applies an edited config: reconnects only when connection settings (or, with
    /// `secretsChanged`, the Keychain credentials) changed.
    func update(_ config: ServerConfig, secretsChanged: Bool = false) {
        guard let i = servers.firstIndex(where: { $0.id == config.id }) else { return }
        let old = servers[i]
        if secretsChanged || old.config.connectionDiffers(from: config) {
            old.stop()
            let s = makeSampler(config)
            servers[i] = s
            s.start()
        } else {
            old.updateDisplay(config)
        }
        save()
        notifyLayout()
    }

    func move(id: UUID, by offset: Int) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard servers.indices.contains(j) else { return }
        servers.swapAt(i, j)
        save()
        notifyLayout()
    }

    /// Adds every config whose host isn't monitored yet; returns how many were added.
    @discardableResult
    func importServers(_ configs: [ServerConfig]) -> Int {
        var added = 0
        for c in configs where !servers.contains(where: { $0.config.host == c.host && $0.config.port == c.port }) {
            let s = makeSampler(c)
            servers.append(s)
            s.start()
            added += 1
        }
        if added > 0 { save(); notifyLayout() }
        return added
    }

    func stopAll() { servers.forEach { $0.stop() } }

    private func makeSampler(_ config: ServerConfig) -> RemoteSampler {
        let s = RemoteSampler(config: config)
        s.onLayoutChange = { [weak self] in self?.notifyLayout() }
        return s
    }

    private func notifyLayout() {
        // @Published emits in willSet; defer so observers read the updated state.
        Task { @MainActor [weak self] in self?.layoutChanged.send(()) }
    }

    private func save() {
        guard !demo, let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [ServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return [] }
        return list
    }

    private static func demoServer() -> RemoteSampler {
        let gb: UInt64 = 1_000_000_000
        let cfg = ServerConfig(name: "linux-server", host: "linux-server.local", user: "admin",
                               services: ["nginx", "postgresql"])
        var s = RemoteSnapshot()
        s.hostname = "linux-server"
        s.hasData = true
        s.cpu = 0.23
        s.memTotal = 16 * 1_073_741_824
        s.memUsed = UInt64(6.4 * 1_073_741_824)
        s.disks = [
            RemoteDisk(mount: "/", device: "/dev/nvme0n1p2", total: 250 * gb, used: 92 * gb, free: 145 * gb),
            RemoteDisk(mount: "/home", device: "/dev/nvme0n1p3", total: 750 * gb, used: 410 * gb, free: 302 * gb),
            RemoteDisk(mount: "/mnt/backup", device: "/dev/sda1", total: 4000 * gb, used: 3550 * gb, free: 250 * gb),
        ]
        s.netIn = 1_240_000
        s.netOut = 86_000
        s.load = [0.42, 0.37, 0.31]
        s.uptime = 12 * 86_400 + 4 * 3_600
        s.os = "Linux"
        s.docker = DockerSummary(running: 5, total: 6)
        s.services = [ServiceState(name: "nginx", state: "active"), ServiceState(name: "postgresql", state: "failed")]
        s.pendingUpdates = 4
        return RemoteSampler(demo: cfg, snapshot: s)
    }
}
