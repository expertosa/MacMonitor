import Foundation
import Security
import MacMonitorCore

/// Polls the local Actions runner process and, when a token is saved, the GitHub runners API.
/// Also watches one volume (default `/Volumes/Data`) and posts alerts when it is missing or low.
@MainActor
final class RunnerMonitor: ObservableObject {
    static let shared = RunnerMonitor()

    @Published private(set) var runners: [RunnerState] = []
    @Published private(set) var volume: VolumeWatch?
    private var timer: Timer?
    private let volumeAlerts = VolumeAlertEngine()
    private weak var alerts: AlertManager?
    private let prefs: Preferences

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
    }

    func start(alerts: AlertManager) {
        guard !SnapshotExporter.isActive else { return }
        self.alerts = alerts
        timer?.invalidate()
        let t = Timer(timeInterval: 30, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    @objc func refresh() {
        var found = RunnerProbe.parseProcessList(Self.processList())
        volume = Self.readVolume(prefs.watchedVolume)
        if let volume, prefs.alerts.enabled {
            let events = volumeAlerts.evaluate(path: volume.path, mounted: volume.mounted,
                                                freeFraction: volume.freeFraction,
                                                minimumFreeFraction: prefs.volumeFreePercent / 100)
            if !events.isEmpty { alerts?.announce(events) }
        }
        let local = found
        runners = local
        guard let repo = prefs.runnerRepo.nilIfEmpty, RunnerProbe.isRepoSlug(repo),
              let token = RunnerSecrets.get(), !token.isEmpty,
              let url = RunnerProbe.runnersURL(repo: repo) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let remote = Optional(RunnerProbe.parseGitHub(data)), !remote.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.runners = local + remote
            }
        }.resume()
    }

    private static func processList() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ax", "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func readVolume(_ path: String) -> VolumeWatch? {
        guard RunnerProbe.isVolumePath(path) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return VolumeWatch(path: path, mounted: false, freeBytes: nil, totalBytes: nil)
        }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        let values = try? url.resourceValues(forKeys: keys)
        let free = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        let total = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        return VolumeWatch(path: path, mounted: true, freeBytes: free, totalBytes: total)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum RunnerSecrets {
    private static let service = "com.tweetso.macmonitor.runners"
    private static let account = "githubToken"

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "MacMonitor GitHub runners token"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var isSet: Bool { get() != nil }
}
