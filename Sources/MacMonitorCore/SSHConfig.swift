import Foundation

/// One concrete `Host` alias from ~/.ssh/config (wildcard patterns are skipped).
public struct SSHHostEntry: Equatable, Sendable, Identifiable {
    public var id: String { alias }
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil) {
        self.alias = alias; self.hostName = hostName; self.user = user; self.port = port
        self.identityFile = identityFile
    }

    /// A server that connects through the alias, so every ~/.ssh/config option (ProxyJump,
    /// IdentityFile, ...) still applies. User/port are copied so the panel shows the real address.
    public func serverConfig() -> ServerConfig {
        ServerConfig(name: alias, host: alias, user: user ?? "", port: port ?? 22)
    }
}

public enum SSHConfigParser {
    /// Parses ssh_config text. `include` receives the argument of an `Include` line and returns the
    /// text of each file it names (the caller resolves paths / globs relative to ~/.ssh).
    /// Only the first value of each option wins, as in ssh itself.
    public static func parse(_ text: String, include: (String) -> [String] = { _ in [] },
                             depth: Int = 0) -> [SSHHostEntry] {
        var entries: [SSHHostEntry] = []
        var current: [Int] = []          // indexes in `entries` the current Host block applies to
        var inMatch = false

        func apply(_ update: (inout SSHHostEntry) -> Void) {
            for i in current { update(&entries[i]) }
        }

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let option = splitOption(line) else { continue }
            let (key, value) = option
            switch key {
            case "host":
                inMatch = false
                current = []
                for pattern in value.split(separator: " ").map(String.init) where isConcrete(pattern) {
                    if let existing = entries.firstIndex(where: { $0.alias == pattern }) {
                        current.append(existing)
                    } else {
                        entries.append(SSHHostEntry(alias: pattern))
                        current.append(entries.count - 1)
                    }
                }
            case "match":
                inMatch = true
                current = []
            case "include":
                guard depth < 8, !inMatch else { continue }
                for file in include(value) {
                    for e in parse(file, include: include, depth: depth + 1)
                    where !entries.contains(where: { $0.alias == e.alias }) {
                        entries.append(e)
                    }
                }
            case "hostname":
                apply { if $0.hostName == nil { $0.hostName = value } }
            case "user":
                apply { if $0.user == nil { $0.user = value } }
            case "port":
                if let p = Int(value), (1...65535).contains(p) { apply { if $0.port == nil { $0.port = p } } }
            case "identityfile":
                apply { if $0.identityFile == nil { $0.identityFile = value } }
            default:
                break
            }
        }
        return entries
    }

    /// "Key value", "Key=value" or "Key = value"; values may be double-quoted.
    static func splitOption(_ line: String) -> (String, String)? {
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let key = line[..<sep].lowercased()
        var rest = line[sep...].drop(while: { $0 == " " || $0 == "\t" || $0 == "=" })
        if let hash = rest.range(of: " #") { rest = rest[..<hash.lowerBound] }
        var value = rest.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    /// Skip patterns ("*", "*.example.com", "!bastion", "web-?") – only real aliases can be imported.
    static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "!" || $0 == "," })
    }
}
