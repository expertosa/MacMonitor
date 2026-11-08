// Temperatures, fans (SMC) and top processes. Direct edition only: the App Sandbox blocks
// opening the AppleSMC user client and reading other processes' task info.
#if !APPSTORE
import Foundation
import IOKit
import Darwin

struct SensorReadings: Equatable {
    var cpuTemp: Double?
    var gpuTemp: Double?
    var fans: [Double] = []           // rpm
    var isEmpty: Bool { cpuTemp == nil && gpuTemp == nil && fans.isEmpty }
}

/// Minimal AppleSMC reader. Keys differ per Mac model; we probe a list of known keys once and
/// keep the ones that return plausible values. Best effort: unknown models just show nothing.
final class SMC {
    // Layout of SMCKeyData_t from the AppleSMC user client (80 bytes).
    private struct KeyData {
        typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let kernelIndex: UInt32 = 2      // kSMCHandleYPCEvent
    private static let cmdReadKey: UInt8 = 5
    private static let cmdKeyInfo: UInt8 = 9

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: KeyData.KeyInfo] = [:]

    private static let cpuKeys = [
        // Intel
        "TC0P", "TC0D", "TC0E", "TC0F", "TCXC",
        // M1
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        // M2
        "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
        // M3 / M4
        "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E", "Tp0V", "Tp0Y", "Tp0e",
    ]
    private static let gpuKeys = [
        "TG0P", "TG0D", "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
    ]
    private var liveCPUKeys: [String] = []
    private var liveGPUKeys: [String] = []
    private var fanCount = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        liveCPUKeys = Self.cpuKeys.filter { plausibleTemp(value($0)) }
        liveGPUKeys = Self.gpuKeys.filter { plausibleTemp(value($0)) }
        fanCount = min(Int(value("FNum") ?? 0), 4)
    }

    deinit { IOServiceClose(conn) }

    func readings() -> SensorReadings {
        var r = SensorReadings()
        r.cpuTemp = average(liveCPUKeys)
        r.gpuTemp = average(liveGPUKeys)
        for i in 0..<fanCount {
            if let rpm = value("F\(i)Ac"), rpm >= 0, rpm < 20_000 { r.fans.append(rpm) }
        }
        return r
    }

    private func average(_ keys: [String]) -> Double? {
        let vals = keys.compactMap { value($0) }.filter { plausibleTemp($0) }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    private func plausibleTemp(_ v: Double?) -> Bool {
        guard let v else { return false }
        return v > 10 && v < 125
    }

    // MARK: Low level

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func string(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)],
               encoding: .ascii) ?? ""
    }

    private func call(_ input: inout KeyData, _ output: inout KeyData) -> Bool {
        var outSize = MemoryLayout<KeyData>.stride
        let kr = IOConnectCallStructMethod(conn, Self.kernelIndex, &input, MemoryLayout<KeyData>.stride,
                                           &output, &outSize)
        return kr == KERN_SUCCESS && output.result == 0
    }

    /// Reads a key and decodes the common numeric SMC types.
    func value(_ key: String) -> Double? {
        let code = Self.fourCC(key)
        var input = KeyData()
        var output = KeyData()
        input.key = code
        let info: KeyData.KeyInfo
        if let cached = infoCache[code] {
            info = cached
        } else {
            input.data8 = Self.cmdKeyInfo
            guard call(&input, &output) else { return nil }
            info = output.keyInfo
            infoCache[code] = info
        }
        guard info.dataSize > 0, info.dataSize <= 32 else { return nil }
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.cmdReadKey
        output = KeyData()
        guard call(&input, &output) else { return nil }
        let size = Int(info.dataSize)
        let b: [UInt8] = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        switch Self.string(info.dataType) {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 ":
            return b.first.map { Double($0) }
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }
}

// MARK: - Top processes

struct ProcessUsage: Identifiable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var cpu: Double              // fraction of one core (1.0 = 100%)
}

/// CPU usage per process from proc_pidinfo deltas. Only processes owned by the current user
/// are visible without root, which covers the apps people usually want to find.
final class ProcessSampler {
    private var prev: [pid_t: UInt64] = [:]     // total cpu time in ns
    private var prevTime: UInt64 = 0             // ns
    private let numer: UInt64
    private let denom: UInt64

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(max(tb.numer, 1))
        denom = UInt64(max(tb.denom, 1))
    }

    func top(_ n: Int) -> [ProcessUsage] {
        let now = mach_absolute_time() * numer / denom
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard got > 0 else { return [] }

        var current: [pid_t: UInt64] = [:]
        var usage: [(pid_t, Double)] = []
        let elapsed = prevTime > 0 && now > prevTime ? Double(now - prevTime) : 0
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            // pti_total_* are Mach absolute time units on Apple Silicon (ns on Intel).
            let t = (info.pti_total_user &+ info.pti_total_system) * numer / denom
            current[pid] = t
            if elapsed > 0, let p = prev[pid], t >= p {
                usage.append((pid, Double(t - p) / elapsed))
            }
        }
        prev = current
        prevTime = now
        return usage.sorted { $0.1 > $1.1 }.prefix(n).map {
            ProcessUsage(pid: $0.0, name: Self.name($0.0), cpu: $0.1)
        }
    }

    private static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let len = proc_name(pid, &buf, UInt32(buf.count))
        return len > 0 ? String(cString: buf) : "pid \(pid)"
    }
}
#endif
