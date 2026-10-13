// swift-tools-version: 6.4
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
    dependencies: [
        // The runtime/debug tooling (serve mcp|mqtt|dev) lives in its own
        // sibling package. This harness keeps the build orchestration policy.
        .package(name: "AxolotyDebug", path: "../../axoloty-debug"),
    ],
    targets: [
        .target(name: "AxolotyVersion", path: "AxolotyVersion"),
        .target(
            name: "AxolotyTooling",
            dependencies: [
                "AxolotyVersion",
                .product(name: "AxolotyDebug", package: "AxolotyDebug"),
                .product(name: "AxolotyProcessLauncher", package: "AxolotyDebug"),
            ],
            path: "AxolotyTooling",
            resources: [.copy("Resources/test-tiers.json")]
        ),
        .executableTarget(
            name: "AxolotyCLI",
            dependencies: ["AxolotyTooling"],
            path: "axoloty-tool"
        ),
        .executableTarget(
            name: "AxolotyResourceLeaseProbe",
            dependencies: ["AxolotyTooling"],
            path: "AxolotyResourceLeaseProbe"
        ),
        .testTarget(
            name: "AxolotyToolingTests",
            dependencies: ["AxolotyTooling", "AxolotyResourceLeaseProbe"],
            path: "AxolotyToolingTests",
            resources: [.copy("Fixtures/legacy-check-plan-v1.json")]
        ),
    ]
)
