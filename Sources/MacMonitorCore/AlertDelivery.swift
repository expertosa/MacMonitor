import Foundation

/// HTTPS bodies for Telegram, Slack and a generic webhook. Secrets are arguments, never stored here.
public struct OutboundAlert: Equatable, Sendable {
    public var url: URL
    public var body: Data
    public var contentType: String

    public init(url: URL, body: Data, contentType: String = "application/json") {
        self.url = url
        self.body = body
        self.contentType = contentType
    }
}

public enum AlertChannels {
    public struct Secrets: Equatable, Sendable {
        public var telegramToken: String?
        public var telegramChat: String?
        public var slackWebhook: String?
        public var webhookURL: String?

        public init(telegramToken: String? = nil, telegramChat: String? = nil,
                    slackWebhook: String? = nil, webhookURL: String? = nil) {
            self.telegramToken = telegramToken
            self.telegramChat = telegramChat
            self.slackWebhook = slackWebhook
            self.webhookURL = webhookURL
        }
    }

    public static func requests(for events: [AlertEvent], settings: AlertSettings, secrets: Secrets) -> [OutboundAlert] {
        guard settings.enabled, !events.isEmpty else { return [] }
        var out: [OutboundAlert] = []
        for event in events {
            let text = event.body.isEmpty ? event.title : "\(event.title)\n\(event.body)"
            if settings.telegram, let item = telegram(token: secrets.telegramToken, chat: secrets.telegramChat, text: text) {
                out.append(item)
            }
            if settings.slack, let item = slack(webhook: secrets.slackWebhook, text: text) {
                out.append(item)
            }
            if settings.webhook, let item = webhook(url: secrets.webhookURL, event: event) {
                out.append(item)
            }
        }
        return out
    }

    /// Bot tokens look like `123456:AA...`. Chat ids are integers or `@channel`.
    public static func telegram(token: String?, chat: String?, text: String) -> OutboundAlert? {
        guard let token, isTelegramToken(token), let chat, isTelegramChat(chat) else { return nil }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return nil }
        let payload: [String: String] = ["chat_id": chat, "text": text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return OutboundAlert(url: url, body: body)
    }

    public static func slack(webhook: String?, text: String) -> OutboundAlert? {
        guard let webhook, let url = URL(string: webhook), isSlackWebhook(url) else { return nil }
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return nil }
        return OutboundAlert(url: url, body: body)
    }

    public static func webhook(url raw: String?, event: AlertEvent) -> OutboundAlert? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        let payload: [String: String] = ["id": event.id, "title": event.title, "body": event.body]
        guard let body = try? JSONEncoder().encode(payload) else { return nil }
        return OutboundAlert(url: url, body: body)
    }

    public static func isTelegramToken(_ token: String) -> Bool {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber) else { return false }
        let secret = parts[1]
        return (20...128).contains(secret.count) && secret.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    public static func isTelegramChat(_ chat: String) -> Bool {
        if chat.hasPrefix("@") {
            let name = chat.dropFirst()
            return (4...64).contains(name.count) && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        let digits = chat.hasPrefix("-") ? chat.dropFirst() : Substring(chat)
        return (1...20).contains(digits.count) && digits.allSatisfy(\.isNumber)
    }

    public static func isSlackWebhook(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "hooks.slack.com" && url.path.hasPrefix("/services/")
    }
}
