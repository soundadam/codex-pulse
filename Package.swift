// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "codex-rollout-inspector",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "CodexRolloutInspectorUI", targets: ["CodexRolloutInspectorUI"]),
        .executable(name: "CodexRolloutInspectorApp", targets: ["CodexRolloutInspectorApp"]),
    ],
    targets: [
        .target(
            name: "Core"
        ),
        .target(
            name: "CodexRolloutInspectorUI",
            dependencies: ["Core"]
        ),
        .executableTarget(
            name: "CodexRolloutInspectorApp",
            dependencies: ["CodexRolloutInspectorUI"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"]
        ),
        .testTarget(
            name: "CodexRolloutInspectorAppTests",
            dependencies: ["Core", "CodexRolloutInspectorUI"]
        ),
    ]
)
