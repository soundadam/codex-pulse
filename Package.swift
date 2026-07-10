// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "codex-pulse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "CodexPulseUI", targets: ["CodexPulseUI"]),
        .executable(name: "CodexPulseApp", targets: ["CodexPulseApp"]),
    ],
    targets: [
        .target(
            name: "Core"
        ),
        .target(
            name: "CodexPulseUI",
            dependencies: ["Core"]
        ),
        .executableTarget(
            name: "CodexPulseApp",
            dependencies: ["CodexPulseUI"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"]
        ),
        .testTarget(
            name: "CodexPulseAppTests",
            dependencies: ["Core", "CodexPulseUI"]
        ),
    ]
)
