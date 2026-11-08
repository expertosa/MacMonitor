import Foundation
import Combine
import MacMonitorCore

/// One immutable snapshot published per tick (single objectWillChange per tick).
struct Snapshot {
    var cpu: Double = 0                 // 0...1
    var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    var memory = MemoryStats()
    var volumes: [Volume] = []          // boot volume first, then other local disks
    var netIn: Double = 0               // bytes/s
    var netOut: Double = 0              // bytes/s
    var gpu: Double?
    var battery: BatteryStats?
    #if !APPSTORE
    var sensors = SensorReadings()
    var processes: [ProcessUsage] = []
    #endif

    var memFraction: Double { memory.fraction }
}

/// Samples this Mac on a timer whose interval follows Preferences.updateInterval.
/// Expensive readers (GPU, battery, SMC, processes) only run when something shows them.
@MainActor
final class Sampler: NSObject, ObservableObject {
    @Published private(set) var snapshot = Snapshot()

    /// Called on the main thread after every tick (status bar title, alerts, widget bridge).
    var onTick: ((Snapshot) -> Void)?

    private let reader = LocalStatsReader()
    private let prefs: Preferences
    private var timer: Timer?
    private var tickCount = 0
    private var prefsSub: AnyCancellable?
    #if !APPSTORE
    private lazy var smc: SMC? = SMC()
    private lazy var processSampler = ProcessSampler()
    #endif

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init()
        snapshot.memory = reader.memory()
        _ = reader.cpuLoad()                    // establish baselines
        _ = reader.networkRates()
        snapshot.volumes = reader.volumes()
        snapshot.battery = reader.battery()
        tick()
        schedule(interval: prefs.updateInterval)
        prefsSub = prefs.$updateInterval.removeDuplicates().dropFirst()
            .sink { [weak self] value in self?.schedule(interval: value) }
    }

    private func schedule(interval: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)   // keep firing while the menu is open
        timer = t
    }

    /// Seconds covered by the history bars.
    var historySeconds: Int { Int(prefs.updateInterval) * snapshot.cpuHistory.count }

    @objc private func tick() {
        var s = snapshot                       // copy, mutate, publish once
        tickCount &+= 1
        let every = { (seconds: Double) -> Bool in
            let n = max(1, Int((seconds / self.prefs.updateInterval).rounded()))
            return self.tickCount % n == 0
        }

        if let c = reader.cpuLoad() { s.cpu = c }
        s.cpuHistory.removeFirst()
        s.cpuHistory.append(s.cpu)
        s.memory = reader.memory()
        if let n = reader.networkRates() { s.netIn = n.rx; s.netOut = n.tx }
        if every(10) { s.volumes = reader.volumes() }

        let menu = prefs.menuBarItems
        if prefs.shows(.gpu) || menu.contains(.gpu) { s.gpu = reader.gpuUtilization() } else { s.gpu = nil }
        if every(10) || menu.contains(.battery) { s.battery = reader.battery() }

        #if !APPSTORE
        if (prefs.shows(.sensors) || menu.contains(.temperature)) && every(3) {
            s.sensors = smc?.readings() ?? SensorReadings()
        } else if !prefs.shows(.sensors) && !menu.contains(.temperature) {
            s.sensors = SensorReadings()
        }
        if prefs.shows(.processes) {
            if every(3) { s.processes = processSampler.top(3) }
        } else if !s.processes.isEmpty {
            s.processes = []
        }
        #endif

        snapshot = s
        onTick?(s)
    }
}
