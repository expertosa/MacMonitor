import Foundation

/// One confirmed remote command. Names are checked before they are pasted into a shell.
public enum RemoteAction: Equatable, Sendable {
    case restartService(String)
    case restartContainer(String)
    case installUpdates

    public var menuTitle: String {
        switch self {
        case .restartService(let name): return "Restart \(name)…"
        case .restartContainer(let name): return "Restart container \(name)…"
        case .installUpdates: return "Install package updates…"
        }
    }

    public var confirmTitle: String {
        switch self {
        case .restartService(let name): return "Restart \(name)?"
        case .restartContainer(let name): return "Restart container \(name)?"
        case .installUpdates: return "Install package updates?"
        }
    }

    public var confirmBody: String {
        switch self {
        case .restartService:
            return "This runs sudo -n systemctl restart on the server. It fails if passwordless sudo is not set up. The output is shown when it finishes."
        case .restartContainer:
            return "This runs docker restart on the server. The output is shown when it finishes."
        case .installUpdates:
            return "This runs apt-get upgrade or dnf upgrade with sudo -n. It can take a few minutes. The output is shown when it finishes."
        }
    }

    /// A single remote shell command, or nil when the name is not safe to interpolate.
    public func command() -> String? {
        switch self {
        case .restartService(let name):
            guard ServerConfig.isValidServiceName(name) else { return nil }
            return "sudo -n systemctl restart -- \(name)"
        case .restartContainer(let name):
            guard RemoteAction.isValidContainerName(name) else { return nil }
            return "docker restart -- \(name)"
        case .installUpdates:
            return "if command -v apt-get >/dev/null 2>&1; then sudo -n apt-get update && sudo -n DEBIAN_FRONTEND=noninteractive apt-get -y upgrade; elif command -v dnf >/dev/null 2>&1; then sudo -n dnf -y upgrade; else echo No apt-get or dnf; exit 1; fi"
        }
    }

    public func remoteShell() -> String? {
        guard let command = command(), !command.contains("'"), !command.contains("\\") else { return nil }
        return "sh -c '" + command + "'"
    }

    public static func isValidContainerName(_ name: String) -> Bool {
        guard (1...128).contains(name.count) else { return false }
        let scalars = Array(name.unicodeScalars)
        func alnum(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
        }
        guard let first = scalars.first, alnum(first) else { return false }
        return scalars.allSatisfy { alnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `name|state` from `docker ps --format`.
    public static func container(from value: String) -> (name: String, running: Bool)? {
        let parts = value.split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, isValidContainerName(name) else { return nil }
        let state = parts.count > 1 ? parts[1] : ""
        guard !state.contains(" ") else { return nil }
        return (name, state == "running")
    }
}
