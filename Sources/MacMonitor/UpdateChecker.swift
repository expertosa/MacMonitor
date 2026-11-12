// Direct edition only: the App Store handles updates itself.
#if !APPSTORE
import Foundation
import AppKit
import MacMonitorCore

/// Checks GitHub Releases once a day and offers the newer version in the menu.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable { var version: String; var url: URL }

    nonisolated static let releasesAPI = URL(string: "https://api.github.com/repos/expertosa/MacMonitor/releases/latest")!
    nonisolated static let releasesPage = URL(string: "https://github.com/expertosa/MacMonitor/releases/latest")!

    @Published private(set) var available: Release?
    @Published private(set) var lastError: String?
    private let prefs: Preferences
    private var timer: Timer?

    init(prefs: Preferences) {
        self.prefs = prefs
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfEnabled() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)   // don't compete with launch
            self.checkIfEnabled()
        }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func checkIfEnabled() {
        guard prefs.checkForUpdates else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        var req = URLRequest(url: Self.releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacMonitor/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var release: Release?
            var problem: String?
            if let error {
                problem = error.localizedDescription
            } else if status == 404 {
                problem = "No releases have been published yet."
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String {
                let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
                if let latest = AppVersion(tag), let mine = AppVersion(Self.currentVersion), mine < latest {
                    release = Release(version: latest.description, url: page)
                }
            } else {
                problem = "Unexpected response (HTTP \(status))."
            }
            Task { @MainActor in
                self.available = release
                self.lastError = problem
                if userInitiated { self.report(release: release, problem: problem) }
            }
        }.resume()
    }

    private func report(release: Release?, problem: String?) {
        let alert = NSAlert()
        if let release {
            alert.messageText = "\(AppDisplay.name) \(release.version) is available"
            alert.informativeText = "You have \(Self.currentVersion)."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        } else if let problem {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = problem
        } else {
            alert.messageText = "\(AppDisplay.name) is up to date"
            alert.informativeText = "Version \(Self.currentVersion) is the latest."
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let release {
            NSWorkspace.shared.open(release.url)
        }
    }
}
#endif
