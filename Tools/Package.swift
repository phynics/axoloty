// swift-tools-version: 6.2
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyTools",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "axoloty-tool", targets: ["AxolotyCLI"]),
        .executable(name: "ax", targets: ["AxolotyCLI"]),
        // Consumed by the Apps package's MCP server, which reports the same
        // canonical test manifest this harness resolves.
        .library(name: "AxolotyTooling", targets: ["AxolotyTooling"]),
        .library(name: "AxolotyVersion", targets: ["AxolotyVersion"]),
    ],
    targets: [
        .target(name: "AxolotyVersion", path: "AxolotyVersion"),
        .target(name: "AxolotyProcessLauncher", path: "AxolotyProcessLauncher", publicHeadersPath: "include"),
        .target(
            name: "AxolotyTooling",
            dependencies: ["AxolotyProcessLauncher", "AxolotyVersion"],
            path: "AxolotyTooling",
            resources: [.copy("Resources/test-tiers.json")]
        ),
        .executableTarget(
            name: "AxolotyCLI",
            dependencies: ["AxolotyTooling"],
            path: "axoloty-tool"
        ),
        .executableTarget(
            name: "AxolotyDeviceLeaseProbe",
            dependencies: ["AxolotyTooling"],
            path: "AxolotyDeviceLeaseProbe"
        ),
        .executableTarget(
            name: "AxolotyResourceLeaseProbe",
            dependencies: ["AxolotyTooling"],
            path: "AxolotyResourceLeaseProbe"
        ),
        .testTarget(
            name: "AxolotyToolingTests",
            dependencies: ["AxolotyTooling", "AxolotyDeviceLeaseProbe", "AxolotyResourceLeaseProbe"],
            path: "AxolotyToolingTests",
            resources: [.copy("Fixtures/legacy-check-plan-v1.json")]
        ),
    ]
)
