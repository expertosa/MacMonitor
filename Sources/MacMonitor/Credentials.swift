import Foundation
import Security
import MacMonitorCore

/// Secrets for the built-in SSH client, kept in the login Keychain (never in user defaults).
enum ServerSecrets {
    enum Kind: String { case privateKey, passphrase, password }
    private static let service = "com.tweetso.macmonitor.ssh"

    private static func account(_ id: UUID, _ kind: Kind) -> String { "\(id.uuidString).\(kind.rawValue)" }

    static func get(_ id: UUID, _ kind: Kind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores (or with nil / empty, deletes) a secret.
    @discardableResult
    static func set(_ value: String?, _ id: UUID, _ kind: Kind) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "MacMonitor SSH \(kind.rawValue)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAll(_ id: UUID) {
        for k in [Kind.privateKey, .passphrase, .password] { set(nil, id, k) }
    }

    static func has(_ id: UUID, _ kind: Kind) -> Bool { get(id, kind) != nil }
}

/// Bot tokens and webhook URLs for alert delivery. Never written to user defaults.
enum AlertSecrets {
    enum Kind: String {
        case telegramToken, telegramChat, slackWebhook, webhookURL
    }
    private static let service = "com.tweetso.macmonitor.alerts"

    static func get(_ kind: Kind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, _ kind: Kind) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "MacMonitor alert \(kind.rawValue)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func has(_ kind: Kind) -> Bool { get(kind) != nil }

    static func snapshot() -> AlertChannels.Secrets {
        AlertChannels.Secrets(telegramToken: get(.telegramToken), telegramChat: get(.telegramChat),
                               slackWebhook: get(.slackWebhook), webhookURL: get(.webhookURL))
    }
}

/// Host keys accepted on first use by the built-in client ("type base64"), per server.
enum KnownHostKeys {
    private static let key = "knownHostKeys"

    static func get(_ id: UUID) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id.uuidString]
    }

    static func set(_ value: String?, _ id: UUID) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[id.uuidString] = value
        UserDefaults.standard.set(all, forKey: key)
    }
}
