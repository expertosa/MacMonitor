import Foundation
import UserNotifications
import MacMonitorCore

/// Evaluates alert rules every tick and posts macOS notifications.
@MainActor
final class AlertManager: NSObject, UNUserNotificationCenterDelegate {
    private let engine = AlertEngine()
    private let prefs: Preferences
    private var authorized = false

    /// UNUserNotificationCenter needs a real app bundle; the bare SwiftPM binary would crash.
    private static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init()
        if Self.available {
            UNUserNotificationCenter.current().delegate = self
            if prefs.alerts.enabled { requestAuthorization() }
        }
    }

    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard Self.available else { completion?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                completion?(granted)
            }
        }
    }

    func evaluate(_ input: AlertInput) {
        let events = engine.evaluate(input, settings: prefs.alerts)
        guard !events.isEmpty else { return }
        if Self.available { for e in events { post(e) } }
        deliver(events)
    }

    func sendTest() {
        let event = AlertEvent(id: "test", title: "MacMonitor alerts are on",
                                body: "You'll be notified when a threshold is crossed.")
        requestAuthorization { granted in
            if granted { self.post(event) }
        }
        deliver([event])
    }

    private func deliver(_ events: [AlertEvent]) {
        let requests = AlertChannels.requests(for: events, settings: prefs.alerts, secrets: AlertSecrets.snapshot())
        for item in requests {
            var request = URLRequest(url: item.url)
            request.httpMethod = "POST"
            request.setValue(item.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = item.body
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    private func post(_ e: AlertEvent) {
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.body
        content.sound = .default
        // Same id replaces an older notification for the same condition.
        let req = UNNotificationRequest(identifier: e.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // Accessory app: show banners even though the app is technically "active".
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
