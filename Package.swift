// swift-tools-version:5.9
import PackageDescription

// MacMonitorCore is pure Foundation (+ Darwin-only samplers behind #if canImport(Darwin)),
// so it and its tests also build on Linux. The app, the shared SwiftUI views and the built-in
// SSH client (MacMonitorSSH, on top of Citadel / SwiftNIO SSH) are macOS-only.
var products: [Product] = [
    .library(name: "MacMonitorCore", targets: ["MacMonitorCore"]),
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "MacMonitorCore", path: "Sources/MacMonitorCore"),
    .testTarget(name: "MacMonitorCoreTests", dependencies: ["MacMonitorCore"],
                path: "Tests/MacMonitorCoreTests"),
]

#if os(macOS)
products += [
    .library(name: "MacMonitorUI", targets: ["MacMonitorUI"]),
    .library(name: "MacMonitorSSH", targets: ["MacMonitorSSH"]),
    .executable(name: "MacMonitor", targets: ["MacMonitor"]),
]
// Citadel is pinned exactly: 0.12+ needs macOS 14 and switched its swift-nio-ssh fork.
// The other pins match what Citadel 0.11.1 declares.
dependencies += [
    .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.11.1"),
    .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3" ..< "4.0.0"),
]
targets += [
    .target(name: "MacMonitorUI", dependencies: ["MacMonitorCore"], path: "Sources/MacMonitorUI"),
    .target(name: "MacMonitorSSH",
            dependencies: [
                "MacMonitorCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/MacMonitorSSH"),
    .executableTarget(name: "MacMonitor", dependencies: ["MacMonitorCore", "MacMonitorUI", "MacMonitorSSH"],
                      path: "Sources/MacMonitor"),
]
#endif

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
