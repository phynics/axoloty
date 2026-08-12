// swift-tools-version: 6.2
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyTools",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "axoloty-tool", targets: ["AxolotyCLI"]),
        .executable(name: "ax", targets: ["AxolotyCLI"]),
    ],
    targets: [
        .target(name: "AxolotyProcessLauncher", path: "AxolotyProcessLauncher", publicHeadersPath: "include"),
        .target(
            name: "AxolotyTooling",
            dependencies: ["AxolotyProcessLauncher"],
            path: "AxolotyTooling",
            resources: [.copy("Resources/test-tiers.json")]
        ),
        .executableTarget(
            name: "AxolotyCLI",
            dependencies: ["AxolotyTooling"],
            path: "axoloty-tool"
        ),
    ]
)
