// swift-tools-version: 6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

/// First-party developer applications built on Axoloty.
///
/// These are programs, not library products: nobody depends on the object
/// inspector or the MCP server as a SwiftPM dependency, they run them. Keeping
/// them out of the root manifest keeps their dependencies out of every
/// consumer's resolution graph -- `swift-sdk` and `swift-log` reach the
/// repository only through the MCP server.
///
/// The root package stays a library package, and the `Tools` package stays the
/// build harness with no dependency on the library at all.
let package = Package(
    name: "AxolotyApps",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "axoloty-inspect", targets: ["AxolotyInspectorCLI"]),
        .executable(name: "axoloty-mcp", targets: ["AxolotyMCPServer"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(path: "../Tools"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.2"),
    ],
    targets: [
        .target(
            name: "AxolotyInspectorCore",
            dependencies: [.product(name: "AxolotyVersion", package: "Tools")],
            path: "AxolotyInspectorCore"
        ),
        .target(
            name: "AxolotyInspectorRuntime",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                "AxolotyInspectorCore",
            ],
            path: "AxolotyInspectorRuntime"
        ),
        .executableTarget(
            name: "AxolotyInspectorCLI",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyMQTT", package: "Axoloty"),
                "AxolotyInspectorCore",
                "AxolotyInspectorRuntime",
            ],
            path: "axoloty-inspect"
        ),
        .target(
            name: "AxolotyMCP",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                "AxolotyInspectorCore",
                "AxolotyInspectorRuntime",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "AxolotyMCP"
        ),
        .executableTarget(
            name: "AxolotyMCPServer",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyMQTT", package: "Axoloty"),
                "AxolotyMCP",
                "AxolotyInspectorCore",
                "AxolotyInspectorRuntime",
                .product(name: "AxolotyTooling", package: "Tools"),
            ],
            path: "axoloty-mcp"
        ),
        .testTarget(
            name: "AxolotyInspectorCoreTests",
            dependencies: ["AxolotyInspectorCore"],
            path: "AxolotyInspectorCoreTests"
        ),
        .testTarget(
            name: "AxolotyInspectorRuntimeTests",
            dependencies: [
                "AxolotyInspectorRuntime",
                "AxolotyInspectorCore",
                .product(name: "Axoloty", package: "Axoloty"),
            ],
            path: "AxolotyInspectorRuntimeTests"
        ),
        .testTarget(
            name: "AxolotyInspectorCLITests",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                "AxolotyInspectorCore",
                "AxolotyInspectorRuntime",
            ],
            path: "AxolotyInspectorCLITests"
        ),
        .testTarget(
            name: "AxolotyMCPTests",
            dependencies: [
                "AxolotyMCP",
                "AxolotyMCPServer",
                .product(name: "AxolotyTooling", package: "Tools"),
            ],
            path: "AxolotyMCPTests"
        ),
    ]
)
