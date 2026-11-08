import Foundation

// Local (this Mac) measurements shared by the app and the widget extension. Everything here
// works inside the App Sandbox. The readers keep the previous counters, so CPU and network
// values are deltas since the previous call.

public struct Volume: Identifiable, Equatable, Codable, Sendable {
    public var id: String          // mount path
    public var name: String
    public var free: Int64
    public var total: Int64
    public init(id: String, name: String, free: Int64, total: Int64) {
        self.id = id; self.name = name; self.free = free; self.total = total
    }
    public var usedFraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }
}

public enum MemoryPressure: Int, Codable, Sendable {
    case unknown = 0, normal = 1, warning = 2, critical = 4

    public var label: String {
        switch self {
        case .unknown: return "–"
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

public struct MemoryStats: Equatable, Codable, Sendable {
    public var used: UInt64 = 0          // active + wired + compressed
    public var total: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressure: MemoryPressure = .unknown
    public init() {}
    public var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct BatteryStats: Equatable, Codable, Sendable {
    public var percent: Double            // 0...100
    public var charging: Bool
    public var onAC: Bool
    public var watts: Double?             // battery charge/discharge power
    public var minutesRemaining: Int?     // to empty (on battery) or full (charging)
    public init(percent: Double, charging: Bool, onAC: Bool, watts: Double? = nil, minutesRemaining: Int? = nil) {
        self.percent = percent; self.charging = charging; self.onAC = onAC
        self.watts = watts; self.minutesRemaining = minutesRemaining
    }
}

#if canImport(Darwin) && os(macOS)
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

public enum LocalHost {
    /// Friendly computer name (System Settings → General → Sharing).
    public static var name: String {
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String?, !n.isEmpty { return n }
        return Host.current().localizedName ?? "This Mac"
    }
}

public final class LocalStatsReader {
    private let host: host_t = mach_host_self()   // cached: mach_host_self() leaks a port ref per call
    private var prevCPUTicks: [UInt32] = []
    private let pageSize = UInt64(vm_kernel_page_size)
    public let memTotal: UInt64 = LocalStatsReader.physicalMemory()

    private var netMIB: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    private var netBuf = [UInt8]()
    private var prevNet: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    public init() {}

    // MARK: CPU

    /// Total CPU busy fraction since the previous call, or nil on the first call / failure.
    public func cpuLoad() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info = info else { return nil }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let states = Int(CPU_STATE_MAX)
        let n = Int(cpuCount) * states
        let hadBaseline = prevCPUTicks.count == n
        if !hadBaseline { prevCPUTicks = [UInt32](repeating: 0, count: n) }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0..<Int(cpuCount) {
            let base = core * states
            for state in 0..<states {
                let now = UInt32(bitPattern: info[base + state])
                let delta = UInt64(now &- prevCPUTicks[base + state])   // wrap-safe
                prevCPUTicks[base + state] = now
                total &+= delta
                if state != Int(CPU_STATE_IDLE) { busy &+= delta }
            }
        }
        guard hadBaseline, total > 0 else { return nil }
        return min(1, Double(busy) / Double(total))
    }

    public static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    // MARK: Memory

    public func memory() -> MemoryStats {
        var m = MemoryStats()
        m.total = memTotal
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let pages = UInt64(stats.active_count) + UInt64(stats.wire_count)
                      + UInt64(stats.compressor_page_count)
            m.used = min(pages * pageSize, memTotal)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            m.pressure = MemoryPressure(rawValue: Int(level)) ?? .unknown
        }
        return m
    }

    static func physicalMemory() -> UInt64 {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &value, &len, nil, 0) != 0 || value == 0 {
            return ProcessInfo.processInfo.physicalMemory
        }
        return value
    }

    // MARK: Disks

    /// Boot volume first, then other local, browsable volumes.
    public func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
                                      .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var vols: [Volume] = []
        for url in urls {
            // Fresh URL so cached resource values are not reused.
            let fresh = URL(fileURLWithPath: url.path)
            guard let v = try? fresh.resourceValues(forKeys: Set(keys)) else { continue }
            let isRoot = v.volumeIsRootFileSystem ?? (url.path == "/")
            guard isRoot || ((v.volumeIsBrowsable ?? false) && (v.volumeIsLocal ?? false)) else { continue }
            guard let total = v.volumeTotalCapacity, total > 0 else { continue }
            var free: Int64 = v.volumeAvailableCapacityForImportantUsage ?? 0
            if free <= 0, let a = v.volumeAvailableCapacity { free = Int64(a) }
            let vol = Volume(id: url.path, name: v.volumeName ?? url.lastPathComponent,
                             free: free, total: Int64(total))
            if isRoot { vols.insert(vol, at: 0) } else { vols.append(vol) }
        }
        return vols
    }

    // MARK: Network (sum of non-loopback interfaces, 64-bit counters)

    /// (download, upload) bytes/s since the previous call; nil on the first call.
    public func networkRates() -> (rx: Double, tx: Double)? {
        guard let c = interfaceCounters() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { prevNet = (c.rx, c.tx, now) }
        guard let p = prevNet, now > p.time else { return nil }
        let dt = now - p.time
        // Counters can go backwards when an interface disappears; clamp to 0.
        return (Double(c.rx >= p.rx ? c.rx - p.rx : 0) / dt, Double(c.tx >= p.tx ? c.tx - p.tx : 0) / dt)
    }

    public func interfaceCounters() -> (rx: UInt64, tx: UInt64)? {
        let mibCount = u_int(6)
        var len = 0
        guard sysctl(&netMIB, mibCount, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        if netBuf.count < len {
            netBuf = [UInt8](repeating: 0, count: len + len / 4)   // headroom; reused afterwards
        }
        len = netBuf.count

        let rtmIFInfo2: UInt8 = 0x12   // RTM_IFINFO2 from <net/route.h>
        let hdrSize = MemoryLayout<if_msghdr>.size
        let msg2Size = MemoryLayout<if_msghdr2>.size
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        let ok = netBuf.withUnsafeMutableBytes { raw -> Bool in
            guard sysctl(&netMIB, mibCount, raw.baseAddress, &len, nil, 0) == 0 else { return false }
            var offset = 0
            while offset + hdrSize <= len {
                // Messages are only 4-byte aligned; if_data64 has UInt64 fields -> unaligned loads.
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen <= 0 { break }
                if hdr.ifm_type == rtmIFInfo2, offset + msg2Size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if (m.ifm_flags & IFF_LOOPBACK) == 0 {
                        totalIn &+= m.ifm_data.ifi_ibytes
                        totalOut &+= m.ifm_data.ifi_obytes
                    }
                }
                offset += msgLen
            }
            return true
        }
        return ok ? (totalIn, totalOut) : nil
    }

    // MARK: Battery

    /// Internal battery state, or nil on Macs without one.
    public func battery() -> BatteryStats? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (desc[key] as? NSNumber)?.intValue
            return BatteryStats(percent: maximum > 0 ? min(100, current / maximum * 100) : 0,
                                charging: charging, onAC: onAC, watts: Self.batteryWatts(),
                                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }

    /// |voltage × amperage| from the AppleSmartBattery registry entry.
    static func batteryWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Int64? {
            guard let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { return nil }
            var n = v.int64Value
            if n > Int64(Int32.max) { n = Int64(Int32(truncatingIfNeeded: n)) }   // stored as unsigned
            return n
        }
        guard let mv = number("Voltage"), let ma = number("InstantAmperage") ?? number("Amperage"), ma != 0 else {
            return nil
        }
        return abs(Double(mv) * Double(ma)) / 1_000_000
    }

    // MARK: GPU

    /// Highest "Device Utilization %" reported by any IOAccelerator (Apple Silicon, Intel, AMD).
    public func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let v = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber {
                best = max(best ?? 0, min(1, max(0, v.doubleValue / 100)))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }
}
#endif
