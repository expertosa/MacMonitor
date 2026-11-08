import Foundation

/// Minimal dotted version ("v1.2.3", "1.10") for comparing GitHub release tags with the app version.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Ignore pre-release / build suffixes: "1.2.0-beta.1" -> "1.2.0".
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let comps = s.split(separator: ".", omittingEmptySubsequences: false)
        let nums = comps.compactMap { Int($0) }
        guard !comps.isEmpty, nums.count == comps.count else { return nil }
        parts = nums
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}
