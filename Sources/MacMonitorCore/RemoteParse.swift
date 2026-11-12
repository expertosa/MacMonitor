import Foundation

// Pure Foundation code (no AppKit / SwiftUI) so it is unit-tested on Linux as well.
// The app launches /usr/bin/ssh with RemoteScript.sshArguments(for:) and feeds stdout into
// RemoteStreamParser; RemoteMetrics turns consecutive raw samples into a RemoteSnapshot.

// MARK: - Server configuration

/// How a server is reached.
public enum SSHAuthKind: String, Codable, CaseIterable, Sendable {
    /// /usr/bin/ssh with the user's keys, agent and ~/.ssh/config (direct edition only).
    case system
    /// Built-in SSH client with a private key stored in the Keychain.
    case key
    /// Built-in SSH client with a password stored in the Keychain.
    case password

    public var label: String {
        switch self {
        case .system: return "System ssh (keys, agent, ~/.ssh/config)"
        case .key: return "Private key file"
        case .password: return "Password"
        }
    }

    /// Uses the in-app SSH client (works inside the App Sandbox).
    public var isBuiltIn: Bool { self != .system }
}

public struct ServerConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var user: String
    public var port: Int
    public var identityFile: String?
    /// systemd units whose state is shown (Linux only), e.g. ["nginx", "postgresql"].
    public var services: [String]
    /// Show only the header row (status, CPU, memory) in the desktop panel.
    public var collapsed: Bool
    /// Hide the per-filesystem bars in the desktop panel.
    public var hideDisks: Bool
    /// Connection method. Secrets for .key / .password live in the Keychain, never here.
    public var auth: SSHAuthKind
    /// Optional bastion. Empty host means a direct connection.
    public var jumpHost: String
    public var jumpUser: String
    public var jumpPort: Int
    /// Built-in client: use ssh-agent when the sandbox allows it. System ssh already uses the agent.
    public var useAgent: Bool

    public init(id: UUID = UUID(), name: String, host: String, user: String, port: Int = 22,
                identityFile: String? = nil, services: [String] = [],
                collapsed: Bool = false, hideDisks: Bool = false, auth: SSHAuthKind = .system,
                jumpHost: String = "", jumpUser: String = "", jumpPort: Int = 22, useAgent: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.services = services
        self.collapsed = collapsed
        self.hideDisks = hideDisks
        self.auth = auth
        self.jumpHost = jumpHost
        self.jumpUser = jumpUser
        self.jumpPort = jumpPort
        self.useAgent = useAgent
    }

    // Tolerant decoding: anything missing (older saved lists) gets a default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decode(String.self, forKey: .host)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? host
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        services = (try c.decodeIfPresent([String].self, forKey: .services) ?? [])
            .filter(ServerConfig.isValidServiceName)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        hideDisks = try c.decodeIfPresent(Bool.self, forKey: .hideDisks) ?? false
        auth = (try? c.decodeIfPresent(SSHAuthKind.self, forKey: .auth)) ?? .system
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost) ?? ""
        jumpUser = try c.decodeIfPresent(String.self, forKey: .jumpUser) ?? ""
        jumpPort = try c.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22
        useAgent = try c.decodeIfPresent(Bool.self, forKey: .useAgent) ?? false
    }

    /// "user@host:port" for menus.
    public var displayAddress: String {
        let u = user.isEmpty ? "" : user + "@"
        return port == 22 ? u + host : "\(u)\(host):\(port)"
    }

    /// The equivalent interactive command, e.g. "ssh -p 2222 -i ~/.ssh/key admin@web-01".
    public var sshCommand: String {
        var parts = ["ssh"]
        if port != 22 { parts += ["-p", String(port)] }
        if auth == .system, let id = identityFile, !id.isEmpty { parts += ["-i", id] }
        parts.append(user.isEmpty ? host : "\(user)@\(host)")
        return parts.joined(separator: " ")
    }

    /// `ssh://user@host:port`, which Terminal opens as a new SSH session.
    public var sshURL: URL? {
        var c = URLComponents()
        c.scheme = "ssh"
        c.host = host
        if !user.isEmpty { c.user = user }
        if port != 22 { c.port = port }
        return c.url
    }

    /// True when a change to `other` needs a new ssh session (as opposed to display-only fields).
    public func connectionDiffers(from other: ServerConfig) -> Bool {
        host != other.host || user != other.user || port != other.port
            || identityFile != other.identityFile || services != other.services || auth != other.auth
            || jumpHost != other.jumpHost || jumpUser != other.jumpUser || jumpPort != other.jumpPort
            || useAgent != other.useAgent
    }

    /// Unit names are pasted into the remote shell loop, so only allow a safe character set.
    public static func isValidServiceName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 100, !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
                || c == "-" || c == "_" || c == "." || c == "@" || c == ":"
        }
    }

    /// Validation for host / user fields typed by the user (they become ssh arguments).
    public static func isSafeArgument(_ s: String) -> Bool {
        !s.hasPrefix("-") && !s.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "'" || $0 == "\"" })
    }
}

// MARK: - Remote shell script

public enum RemoteScript {
    /// Slow checks (services, reboot flag, docker) run every Nth loop (2 s each) ...
    public static let extrasEvery = 30
    /// ... and the pending-updates count every Nth loop (30 min).
    public static let updatesEvery = 900

    /// POSIX sh loop run on the server. Deliberately a single line containing no single quotes
    /// and no backslashes, so wrapping it in '...' is safe under sh, bash, zsh, fish and csh
    /// login shells. Prints one ##BEGIN ... ##END block every 2 s.
    /// Linux servers report /proc data; macOS servers report sysctl / vm_stat / netstat / top.
    public static func script(services: [String] = []) -> String {
        let svc = services.filter(ServerConfig.isValidServiceName).joined(separator: " ")
        return [
            "echo \"##HOST $(hostname 2>/dev/null || uname -n)\";",
            "OS=$(uname -s 2>/dev/null); echo \"##OS $OS\";",
            "SVC=\"\(svc)\";",
            "T=; command -v timeout >/dev/null 2>&1 && T=\"timeout 5\";",
            "U=; command -v timeout >/dev/null 2>&1 && U=\"timeout 60\";",
            "if df -P -B1 -x tmpfs / >/dev/null 2>&1; then M=1; else M=1024; fi;",
            "N=0;",
            "while :; do",
            "echo \"##BEGIN $M\";",
            "if [ \"$OS\" = Darwin ]; then",
            "echo \"##MEMSIZE $(sysctl -n hw.memsize 2>/dev/null)\";",
            "echo \"##LOAD $(sysctl -n vm.loadavg 2>/dev/null | tr -d {})\";",
            "echo \"##BOOT $(sysctl -n kern.boottime 2>/dev/null)\";",
            "echo \"##NOW $(date +%s)\";",
            "echo \"##TOPCPU $(top -l 2 -n 0 -s 1 2>/dev/null | grep CPU.usage | tail -n 1)\";",
            "echo \"##VMSTAT\"; vm_stat 2>/dev/null;",
            "echo \"##DF\"; $T df -Pk 2>/dev/null;",
            "echo \"##NETSTAT\"; netstat -ibn 2>/dev/null;",
            "else",
            "head -n 1 /proc/stat;",
            "grep -E \"^(MemTotal|MemFree|MemAvailable|Buffers|Cached):\" /proc/meminfo;",
            "echo \"##UP $(cat /proc/uptime)\";",
            "echo \"##LOAD $(cat /proc/loadavg)\";",
            "echo \"##DF\";",
            "if [ $M = 1 ]; then $T df -P -B1 -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null;",
            "else $T df -Pk 2>/dev/null; fi;",
            "echo \"##NET\";",
            "tail -n +3 /proc/net/dev;",
            "if [ $((N % \(extrasEvery))) = 0 ]; then",
            "echo \"##EXTRA\";",
            "if [ -f /var/run/reboot-required ]; then echo \"##REBOOT 1\"; else echo \"##REBOOT 0\"; fi;",
            "for S in $SVC; do echo \"##SVC $S $(systemctl is-active $S 2>/dev/null | head -n 1)\"; done;",
            "if command -v docker >/dev/null 2>&1; then echo \"##DOCKER\"; $T docker ps -a --format {{.State}} 2>/dev/null; fi;",
            "fi;",
            "if [ $((N % \(updatesEvery))) = 0 ]; then",
            "if command -v apt-get >/dev/null 2>&1; then echo \"##UPDATES $($U apt-get -s upgrade 2>/dev/null | grep -c \"^Inst \")\";",
            "elif command -v dnf >/dev/null 2>&1; then echo \"##UPDATES $($U dnf -q -C check-update 2>/dev/null | grep -c -E \"^[a-zA-Z0-9]\")\";",
            "fi;",
            "fi;",
            "fi;",
            "echo \"##END\";",
            "N=$((N + 1));",
            "sleep 2 || exit;",
            "done",
        ].joined(separator: " ")
    }

    /// The single remote command string handed to ssh (interpreted by the user's login shell).
    public static func remoteCommand(services: [String] = []) -> String {
        "sh -c '" + script(services: services) + "'"
    }

    /// Full argument list for /usr/bin/ssh.
    public static func sshArguments(for s: ServerConfig) -> [String] {
        var args = ["-T",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "LogLevel=ERROR",            // hide "Permanently added ... to known hosts"
                    "-p", String(s.port)]
        if let id = s.identityFile?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            args += ["-i", (id as NSString).expandingTildeInPath]
        }
        if let jump = OpenSSHKeyInfo.proxyJump(user: s.jumpUser, host: s.jumpHost, port: s.jumpPort) {
            args += ["-J", jump]
        }
        args += ["--", s.user.isEmpty ? s.host : "\(s.user)@\(s.host)", remoteCommand(services: s.services)]
        return args
    }
}

// MARK: - Raw samples (one per ##BEGIN ... ##END block)

public struct RemoteDisk: Identifiable, Equatable, Sendable, Codable {
    public var id: String { mount }
    public var mount: String
    public var device: String
    public var total: UInt64       // bytes
    public var used: UInt64        // bytes
    public var free: UInt64        // bytes available to non-root users

    public init(mount: String, device: String, total: UInt64, used: UInt64, free: UInt64) {
        self.mount = mount; self.device = device; self.total = total; self.used = used; self.free = free
    }

    /// Same definition as df's "Use%": used / (used + available).
    public var usedFraction: Double {
        let denom = Double(used) + Double(free)
        return denom > 0 ? Double(used) / denom : 0
    }
}

public struct ServiceState: Equatable, Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    /// systemctl is-active output: active, inactive, failed, activating, ... ("" = unknown).
    public var state: String
    public init(name: String, state: String) { self.name = name; self.state = state }
    public var isActive: Bool { state == "active" }
    /// Known and not running (an empty state means systemctl isn't available).
    public var isDown: Bool { !state.isEmpty && state != "active" && state != "activating" && state != "reloading" }
}

public struct DockerSummary: Equatable, Sendable, Codable {
    public var running: Int
    public var total: Int
    public init(running: Int, total: Int) { self.running = running; self.total = total }
}

public struct RawSample: Sendable {
    public var cpuTotal: UInt64?
    public var cpuIdle: UInt64?
    /// Busy fraction measured directly by the server (macOS `top`), instead of /proc/stat deltas.
    public var cpuBusy: Double?
    public var memTotal: UInt64?           // bytes
    public var memAvailable: UInt64?       // bytes
    /// Monotonic-ish clock used for network rates (Linux: /proc/uptime; macOS: epoch seconds).
    public var clock: Double?
    public var uptime: Double?             // seconds since boot
    public var load: [Double] = []
    public var disks: [RemoteDisk]?        // nil when the df section was empty (e.g. timed out)
    public var netRx: UInt64?
    public var netTx: UInt64?
    /// Set when the slow checks ran in this block (services / reboot / docker are then authoritative).
    public var extrasRan = false
    public var rebootRequired: Bool?
    public var services: [ServiceState] = []
    public var docker: DockerSummary?
    public var pendingUpdates: Int?
    public var arrival: TimeInterval = 0   // local monotonic time the block was completed
    public init() {}
}

/// Incremental parser for the ssh stdout stream. Fed from a background readabilityHandler;
/// all state is behind a lock so it is safe whichever thread calls it.
public final class RemoteStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var inBlock = false
    private var multiplier: UInt64 = 1
    private var section = ""
    private var current = RawSample()
    private var dfLines: [String] = []
    private var netRx: UInt64 = 0
    private var netTx: UInt64 = 0
    private var sawNet = false
    private var memFallback: [String: UInt64] = [:]
    private var vmPages: [String: UInt64] = [:]
    private var vmPageSize: UInt64 = 4096
    private var memSize: UInt64?
    private var bootSec: Double?
    private var nowSec: Double?
    private var dockerStates: [String]?
    private var os: String = ""

    public struct Output: Sendable {
        public var hostname: String?
        public var os: String?
        public var samples: [RawSample] = []
    }

    public init() {}

    private var isDarwin: Bool { os == "Darwin" }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        inBlock = false
    }

    public func feed(_ data: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Output {
        lock.lock(); defer { lock.unlock() }
        var out = Output()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line: line, now: now, out: &out)
        }
        if buffer.count > 1_000_000 { buffer.removeAll() }   // garbage without newlines: drop it
        // Data.removeSubrange keeps a sliced start index; re-base occasionally.
        if buffer.startIndex != 0 { buffer = Data(buffer) }
        return out
    }

    private func beginBlock(_ line: String) {
        inBlock = true
        multiplier = UInt64(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 1
        if multiplier == 0 { multiplier = 1 }
        current = RawSample()
        section = ""
        dfLines.removeAll(keepingCapacity: true)
        netRx = 0; netTx = 0; sawNet = false
        memFallback.removeAll(keepingCapacity: true)
        vmPages.removeAll(keepingCapacity: true)
        memSize = nil; bootSec = nil; nowSec = nil
        dockerStates = nil
    }

    private func endBlock(now: TimeInterval, out: inout Output) {
        if !dfLines.isEmpty {
            let disks = RemoteParse.disks(fromDF: dfLines, multiplier: multiplier, darwin: isDarwin)
            if !disks.isEmpty { current.disks = disks }
        }
        if sawNet { current.netRx = netRx; current.netTx = netTx }
        if current.memAvailable == nil, memFallback.count == 3 {
            current.memAvailable = memFallback.values.reduce(0, +)
        }
        if isDarwin {
            if let total = memSize, total > 0 {
                current.memTotal = total
                let pages = ["Pages active", "Pages wired down", "Pages occupied by compressor"]
                    .compactMap { vmPages[$0] }
                if pages.count == 3 {
                    let used = min(pages.reduce(0, &+) &* vmPageSize, total)
                    current.memAvailable = total - used
                }
            }
            if let n = nowSec {
                current.clock = n
                if let b = bootSec, n > b { current.uptime = n - b }
            }
        }
        if let states = dockerStates {
            current.docker = DockerSummary(running: states.filter { $0 == "running" }.count, total: states.count)
        }
        current.arrival = now
        out.samples.append(current)
        inBlock = false
    }

    private func handle(line: String, now: TimeInterval, out: inout Output) {
        if line.hasPrefix("##") {
            if line.hasPrefix("##HOST ") {
                let h = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if !h.isEmpty { out.hostname = h }
                return
            }
            if line.hasPrefix("##OS") {
                os = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                out.os = os
                return
            }
            if line.hasPrefix("##BEGIN") { beginBlock(line); return }
            guard inBlock else { return }
            let value: String
            if let sp = line.firstIndex(of: " ") {
                value = line[line.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            } else {
                value = ""
            }
            let tag = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            switch tag {
            case "##UP":
                let up = value.split(separator: " ").first.flatMap { Double($0) }
                current.uptime = up
                current.clock = up
            case "##LOAD":
                current.load = value.split(separator: " ").prefix(3).compactMap { Double($0) }
            case "##MEMSIZE": memSize = UInt64(value)
            case "##BOOT": bootSec = RemoteParse.bootTime(value)
            case "##NOW": nowSec = Double(value)
            case "##TOPCPU": current.cpuBusy = RemoteParse.topCPUBusy(value)
            case "##EXTRA": current.extrasRan = true
            case "##REBOOT": current.rebootRequired = value == "1"
            case "##SVC":
                let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                if let name = parts.first, ServerConfig.isValidServiceName(name) {
                    current.services.append(ServiceState(name: name, state: parts.count > 1 ? parts[1] : ""))
                }
            case "##UPDATES": current.pendingUpdates = Int(value)
            case "##DF": section = "df"
            case "##NET": section = "net"
            case "##NETSTAT": section = "netstat"
            case "##VMSTAT": section = "vmstat"
            case "##DOCKER": section = "docker"; dockerStates = []
            case "##END": endBlock(now: now, out: &out)
            default: break
            }
            return
        }
        guard inBlock else { return }   // login banners, .bashrc noise, etc.

        switch section {
        case "df":
            dfLines.append(line)
        case "net":
            if let n = RemoteParse.netDevLine(line), RemoteParse.countsInterface(n.name) {
                netRx &+= n.rx; netTx &+= n.tx; sawNet = true
            }
        case "netstat":
            if let n = RemoteParse.netstatLine(line), RemoteParse.countsDarwinInterface(n.name) {
                netRx &+= n.rx; netTx &+= n.tx; sawNet = true
            }
        case "vmstat":
            if line.hasPrefix("Mach Virtual Memory Statistics") {
                if let size = RemoteParse.vmStatPageSize(line) { vmPageSize = size }
            } else if let kv = RemoteParse.vmStatLine(line) {
                vmPages[kv.key] = kv.pages
            }
        case "docker":
            let state = line.trimmingCharacters(in: .whitespaces)
            if !state.isEmpty, !state.contains(" ") { dockerStates?.append(state) }
        default:
            if line.hasPrefix("cpu ") {
                if let c = RemoteParse.cpuLine(line) {
                    current.cpuTotal = c.total; current.cpuIdle = c.idle
                }
            } else if let m = RemoteParse.meminfoLine(line) {
                let key = m.key, kb = m.kb
                switch key {
                case "MemTotal": current.memTotal = kb * 1024
                case "MemAvailable": current.memAvailable = kb * 1024
                case "MemFree", "Buffers", "Cached":
                    memFallback[key] = kb * 1024    // for kernels < 3.14 without MemAvailable
                default: break
                }
            }
        }
    }
}

public enum RemoteParse {
    /// "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
    /// total = first 8 fields (guest time is already included in user/nice); idle = idle + iowait.
    public static func cpuLine(_ line: String) -> (total: UInt64, idle: UInt64)? {
        let f = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard f.count >= 4 else { return nil }
        let total = f.prefix(8).reduce(0, &+)
        let idle = f[3] &+ (f.count > 4 ? f[4] : 0)
        return (total, idle)
    }

    /// "MemTotal:       16314564 kB" -> ("MemTotal", 16314564)
    public static func meminfoLine(_ line: String) -> (key: String, kb: UInt64)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        let rest = line[line.index(after: colon)...].split(separator: " ")
        guard let v = rest.first.flatMap({ UInt64($0) }) else { return nil }
        return (key, v)
    }

    /// "  eth0: 123 456 ... (8 rx fields) 789 ..." -> ("eth0", rxBytes, txBytes)
    public static func netDevLine(_ line: String) -> (name: String, rx: UInt64, tx: UInt64)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let f = line[line.index(after: colon)...].split(separator: " ")
        guard f.count >= 9, let rx = UInt64(f[0]), let tx = UInt64(f[8]) else { return nil }
        return (name, rx, tx)
    }

    /// Exclude loopback and per-container virtual links whose traffic is also counted on the
    /// physical NIC / bridge (otherwise container traffic would be counted two or three times).
    public static func countsInterface(_ name: String) -> Bool {
        if name == "lo" { return false }
        for p in ["veth", "docker", "br-", "virbr", "cni", "flannel", "cali", "vxlan"] where name.hasPrefix(p) {
            return false
        }
        return true
    }

    /// macOS `netstat -ibn` link-layer row:
    /// "en0  1500  <Link#11>  aa:bb:cc:dd:ee:ff  Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll"
    /// The Address column is empty for some interfaces, which shifts the columns left by one.
    public static func netstatLine(_ line: String) -> (name: String, rx: UInt64, tx: UInt64)? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 10, f[2].hasPrefix("<Link#") else { return nil }
        var name = String(f[0])
        if name.hasSuffix("*") { name.removeLast() }       // '*' marks an interface that is down
        let base = f.count >= 11 ? 6 : 5
        guard let rx = UInt64(f[base]), let tx = UInt64(f[base + 3]) else { return nil }
        return (name, rx, tx)
    }

    /// On macOS only physical en* interfaces carry real traffic (utun/bridge/awdl duplicate it).
    public static func countsDarwinInterface(_ name: String) -> Bool { name.hasPrefix("en") }

    /// "Mach Virtual Memory Statistics: (page size of 16384 bytes)" -> 16384
    public static func vmStatPageSize(_ line: String) -> UInt64? {
        guard let r = line.range(of: "page size of ") else { return nil }
        return line[r.upperBound...].split(separator: " ").first.flatMap { UInt64($0) }
    }

    /// "Pages active:                         123456." -> ("Pages active", 123456)
    public static func vmStatLine(_ line: String) -> (key: String, pages: UInt64)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if v.hasSuffix(".") { v.removeLast() }
        guard let pages = UInt64(v) else { return nil }
        return (key, pages)
    }

    /// "CPU usage: 3.33% user, 5.55% sys, 91.11% idle" -> 0.0889
    public static func topCPUBusy(_ line: String) -> Double? {
        for part in line.split(separator: ",") where part.contains("idle") {
            let token = part.split(separator: " ").first { $0.hasSuffix("%") }
            if let token, let idle = Double(token.dropLast()) {
                return min(1, max(0, 1 - idle / 100))
            }
        }
        return nil
    }

    /// "{ sec = 1700000000, usec = 12345 } Tue Nov 14 ..." -> 1700000000
    public static func bootTime(_ value: String) -> Double? {
        guard let r = value.range(of: "sec = ") else { return nil }
        let digits = value[r.upperBound...].prefix { $0.isNumber }
        return Double(String(digits))
    }

    static let pseudoFS: Set<String> = ["tmpfs", "devtmpfs", "overlay", "squashfs", "efivarfs",
                                        "udev", "none", "shm", "cgroup", "cgroup2", "proc",
                                        "sysfs", "devpts", "run", "rootfs", "devfs", "map"]

    public static func skipMount(_ m: String) -> Bool {
        if m.hasPrefix("/boot") || m.hasPrefix("/snap") || m.hasPrefix("/run") { return true }
        for p in ["/dev", "/sys", "/proc"] where m == p || m.hasPrefix(p + "/") { return true }
        // macOS: sealed-system helper volumes, recovery, Time Machine snapshots, simulators.
        for p in ["/System/Volumes", "/Volumes/Recovery", "/Volumes/.timemachine", "/private/var/vm",
                  "/Library/Developer/CoreSimulator", "/Volumes/com.apple.TimeMachine"] where m.hasPrefix(p) {
            return true
        }
        return m.hasPrefix("/var/lib/docker/") || m.hasPrefix("/var/snap/")
    }

    /// `df -P` lines: "Filesystem 1-blocks Used Available Capacity Mounted on" + one row per fs.
    /// Skips /boot*, /snap*, /run* (+ /dev, /sys, /proc for the df -Pk fallback), pseudo
    /// filesystems, zero-sized ones, and duplicate mounts of the same device (shortest mount wins).
    /// On macOS (APFS) volumes share their container's space, so used = total - available.
    public static func disks(fromDF lines: [String], multiplier: UInt64, darwin: Bool = false) -> [RemoteDisk] {
        var byDevice: [String: RemoteDisk] = [:]
        var order: [String] = []
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6, f[0] != "Filesystem",
                  let blocks = UInt64(f[1]), var used = UInt64(f[2]), let avail = UInt64(f[3]) else { continue }
            let device = String(f[0])
            let mount = f[5...].joined(separator: " ")   // mount points may contain spaces
            guard mount.hasPrefix("/"), blocks > 0, !pseudoFS.contains(device) else { continue }
            if mount != "/" && skipMount(mount) { continue }
            if darwin { used = blocks > avail ? blocks - avail : 0 }
            let disk = RemoteDisk(mount: mount, device: device,
                                  total: blocks &* multiplier, used: used &* multiplier,
                                  free: avail &* multiplier)
            if let existing = byDevice[device] {
                if mount.count < existing.mount.count { byDevice[device] = disk }
            } else {
                byDevice[device] = disk
                order.append(device)
            }
        }
        var result = order.compactMap { byDevice[$0] }
        if let i = result.firstIndex(where: { $0.mount == "/" }), i > 0 {
            result.insert(result.remove(at: i), at: 0)
        }
        return result
    }
}

// MARK: - Derived metrics (deltas between consecutive samples)

public struct RemoteSnapshot: Equatable, Sendable {
    public var hostname: String?
    public var os: String?
    public var hasData = false
    public var cpu: Double = 0                 // 0...1
    public var memUsed: UInt64 = 0             // bytes
    public var memTotal: UInt64 = 0            // bytes
    public var disks: [RemoteDisk] = []
    public var netIn: Double = 0               // bytes/s
    public var netOut: Double = 0              // bytes/s
    public var load: [Double] = []             // 1, 5, 15 min
    public var uptime: Double?                 // seconds
    public var rebootRequired: Bool?
    public var services: [ServiceState] = []
    public var docker: DockerSummary?
    public var pendingUpdates: Int?

    public init() {}

    public var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    public var fullestDisk: RemoteDisk? { disks.max { $0.usedFraction < $1.usedFraction } }
    public var downServices: [ServiceState] { services.filter(\.isDown) }
}

public struct RemoteMetrics {
    private var prevCPU: (total: UInt64, idle: UInt64)?
    private var prevNet: (rx: UInt64, tx: UInt64, time: Double)?

    public init() {}

    /// Forget baselines (call when a new ssh connection starts).
    public mutating func resetBaselines() { prevCPU = nil; prevNet = nil }

    public mutating func apply(_ r: RawSample, to s: inout RemoteSnapshot) {
        if let busy = r.cpuBusy {
            s.cpu = busy
        } else if let total = r.cpuTotal, let idle = r.cpuIdle {
            if let p = prevCPU, total > p.total {
                let dt = total - p.total
                let di = idle >= p.idle ? idle - p.idle : 0
                s.cpu = min(1, max(0, 1 - Double(di) / Double(dt)))
            }
            prevCPU = (total, idle)
        }
        if let total = r.memTotal, total > 0 {
            s.memTotal = total
            if let avail = r.memAvailable { s.memUsed = avail < total ? total - avail : 0 }
        }
        if let disks = r.disks { s.disks = disks }
        if r.load.count == 3 { s.load = r.load }
        if let up = r.uptime { s.uptime = up }
        if let rx = r.netRx, let tx = r.netTx {
            let t = r.clock ?? r.arrival
            if let p = prevNet, t > p.time {
                let dt = t - p.time
                s.netIn = Double(rx >= p.rx ? rx - p.rx : 0) / dt     // clamp counter resets
                s.netOut = Double(tx >= p.tx ? tx - p.tx : 0) / dt
            }
            prevNet = (rx, tx, t)
        }
        if r.extrasRan {
            s.rebootRequired = r.rebootRequired
            s.services = r.services
            s.docker = r.docker
        }
        if let n = r.pendingUpdates { s.pendingUpdates = n }
        s.hasData = true
    }
}
