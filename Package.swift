// swift-tools-version:5.9
import PackageDescription

// MacMonitorCore is pure Foundation (+ Darwin-only samplers behind #if canImport(Darwin)),
// so it and its tests also build on Linux. The app and the shared SwiftUI views are macOS-only.
var products: [Product] = [
    .library(name: "MacMonitorCore", targets: ["MacMonitorCore"]),
]
var targets: [Target] = [
    .target(name: "MacMonitorCore", path: "Sources/MacMonitorCore"),
    .testTarget(name: "MacMonitorCoreTests", dependencies: ["MacMonitorCore"],
                path: "Tests/MacMonitorCoreTests"),
]

#if os(macOS)
products += [
    .library(name: "MacMonitorUI", targets: ["MacMonitorUI"]),
    .executable(name: "MacMonitor", targets: ["MacMonitor"]),
]
targets += [
    .target(name: "MacMonitorUI", dependencies: ["MacMonitorCore"], path: "Sources/MacMonitorUI"),
    .executableTarget(name: "MacMonitor", dependencies: ["MacMonitorCore", "MacMonitorUI"],
                      path: "Sources/MacMonitor"),
]
#endif

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
