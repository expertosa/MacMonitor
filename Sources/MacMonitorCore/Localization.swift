import Foundation

/// Arabic is right-to-left. The brand name MacMonitor stays in Latin letters.
public enum InterfaceDirection {
    public static func isRightToLeft(_ languageCodes: [String]) -> Bool {
        guard let first = languageCodes.first?.lowercased() else { return false }
        let language = first.split(separator: "-").first.map(String.init) ?? first
        return language == "ar"
    }
}

/// Looks up `Localizable.xcstrings` in the app bundle. With no translation, the English key is returned.
public func localizedUI(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
