// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetworkMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NetworkMonitor", targets: ["NetworkMonitorApp"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "NetworkTools", targets: ["NetworkTools"]),
    ],
    targets: [
        // Model-agnostic agent loop, tool protocol and message types. No UI, no OS calls.
        .target(name: "AgentCore"),
        // Read-only system tools exposed to the agent.
        .target(name: "NetworkTools", dependencies: ["AgentCore"]),
        // Menu bar shell: popover chat UI wired to the agent.
        .executableTarget(name: "NetworkMonitorApp", dependencies: ["AgentCore", "NetworkTools"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "NetworkToolsTests", dependencies: ["NetworkTools"]),
    ]
)
