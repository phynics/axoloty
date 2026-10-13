// swift-tools-version: 6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyTools",
    platforms: [.macOS(.v15)],
    // The harness is not a library. Its only external consumer was the Apps
    // package, which now lives in the sibling axoloty-debug package. The
    // AxolotyTooling and AxolotyVersion targets remain internal to the two
    // executables below.
    products: [
        .executable(name: "axoloty-tool", targets: ["AxolotyCLI"]),
        .executable(name: "ax", targets: ["AxolotyCLI"]),
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
