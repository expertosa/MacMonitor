import Foundation

public struct RunnerState: Equatable, Sendable, Codable, Identifiable {
    public enum Status: String, Codable, Sendable { case online, offline, busy }
    public enum Source: String, Codable, Sendable { case local, github }

    public var id: String
    public var name: String
    public var status: Status
    public var source: Source

    public init(id: String, name: String, status: Status, source: Source) {
        self.id = id
        self.name = name
        self.status = status
        self.source = source
    }
}

public struct VolumeWatch: Equatable, Sendable {
    public var path: String
    public var mounted: Bool
    public var freeBytes: UInt64?
    public var totalBytes: UInt64?

    public init(path: String, mounted: Bool, freeBytes: UInt64?, totalBytes: UInt64?) {
        self.path = path
        self.mounted = mounted
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }

    public var freeFraction: Double? {
        guard mounted, let free = freeBytes, let total = totalBytes, total > 0 else { return nil }
        return Double(free) / Double(total)
    }
}

public enum RunnerProbe {
    /// Lines from `ps -ax -o command=`. A listener means the runner is online; a worker means it is busy.
    public static func parseProcessList(_ text: String) -> [RunnerState] {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        let listener = lines.contains { $0.contains("Runner.Listener") || $0.contains("actions-runner") && $0.contains("run") }
        let worker = lines.contains { $0.contains("Runner.Worker") }
        guard listener || worker else { return [] }
        return [RunnerState(id: "local", name: "This Mac", status: worker ? .busy : .online, source: .local)]
    }

    /// App Store Connect is not involved. This is the Actions list-runners JSON.
    public static func parseGitHub(_ data: Data) -> [RunnerState] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["runners"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let id = (row["id"] as? Int).map(String.init) ?? name
            let busy = (row["busy"] as? Bool) ?? false
            let raw = (row["status"] as? String) ?? "offline"
            let status: RunnerState.Status
            if raw != "online" { status = .offline }
            else if busy { status = .busy }
            else { status = .online }
            return RunnerState(id: "gh:\(id)", name: name, status: status, source: .github)
        }
    }

    public static func isRepoSlug(_ value: String) -> Bool {
        let parts = value.split(separator: "/")
        guard parts.count == 2 else { return false }
        func ok(_ part: Substring) -> Bool {
            !part.isEmpty && part.count <= 100 && part.allSatisfy { c in
                c.isLetter || c.isNumber || c == "-" || c == "_" || c == "."
            }
        }
        return ok(parts[0]) && ok(parts[1])
    }

    public static func runnersURL(repo: String) -> URL? {
        guard isRepoSlug(repo) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/actions/runners?per_page=100")
    }

    public static func isVolumePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count <= 1024 && !path.contains("\n") && !path.contains("\0")
    }
}

/// One-shot alerts for a watched volume. Fires when it is missing, and when free space drops
/// under the threshold. Re-arms after the condition clears.
public final class VolumeAlertEngine {
    private var missingFired = false
    private var lowFired = false

    public init() {}

    public func evaluate(path: String, mounted: Bool, freeFraction: Double?, minimumFreeFraction: Double) -> [AlertEvent] {
        guard RunnerProbe.isVolumePath(path) else { missingFired = false; lowFired = false; return [] }
        var events: [AlertEvent] = []
        if !mounted {
            if !missingFired {
                missingFired = true
                events.append(AlertEvent(id: "volume-missing", title: "\(path) is not mounted",
                                          body: "The watched volume is missing."))
            }
            lowFired = false
            return events
        }
        if missingFired {
            missingFired = false
            events.append(AlertEvent(id: "volume-missing", title: "\(path) is mounted", body: "The watched volume is back."))
        }
        if let free = freeFraction, free <= minimumFreeFraction {
            if !lowFired {
                lowFired = true
                events.append(AlertEvent(id: "volume-low", title: "\(path) is low on space",
                                          body: String(format: "%.0f%% free.", free * 100)))
            }
        } else if lowFired {
            lowFired = false
        }
        return events
    }
}
