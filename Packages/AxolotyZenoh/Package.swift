// swift-tools-version:6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

// The Zenoh adapter is its own SwiftPM package so that no existing Axoloty
// product, and no build of the root package, resolves or links Zenoh. See
// docs/adr/0007-zenoh-adapter-package-boundary.md. The package depends on the
// root package by path and publishes AxolotyZenohCore, the
// Embedded-Swift-compatible core, alongside AxolotyZenoh, the host product whose
// ZenohBinding conforms to AxolotyRuntimeTransport.
let package = Package(
    name: "AxolotyZenoh",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "AxolotyZenohCore", targets: ["AxolotyZenohCore"]),
        .library(name: "AxolotyZenoh", targets: ["AxolotyZenoh"]),
    ],
    dependencies: [
        // ADR 0007 explicitly permits a path dependency on Axoloty; reusing
        // AxolotyWire's borrowed ByteSlice avoids a second byte-view contract.
        .package(name: "Axoloty", path: "../.."),
    ],
    targets: [
        // Backend-selection seam: this target name and the façade header stay
        // fixed while its implementation/dependency is selected for a
        // conformance run. The suite imports only this façade module.
        // Consumes the pinned prebuilt zenoh-c archive through pkg-config; see
        // docs/adr/0006-zenoh-host-dependency-packaging.md.
        .systemLibrary(
            name: "CZenohC",
            pkgConfig: "zenohc"
        ),
        .target(
            name: "CAxolotyZenoh",
            dependencies: ["CZenohC"],
            path: "Sources/CAxolotyZenoh",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AxolotyZenohCore",
            dependencies: [
                "CAxolotyZenoh",
                .product(name: "AxolotyWire", package: "Axoloty"),
            ],
            path: "Sources/AxolotyZenohCore"
        ),
        .target(
            name: "AxolotyZenoh",
            dependencies: [
                "AxolotyZenohCore",
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyProtocol", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
            ],
            path: "Sources/AxolotyZenoh"
        ),
        .target(
            name: "AxolotyZenohContract",
            path: "Sources/AxolotyZenohContract",
            resources: [.copy("Resources/axoloty-zenoh-facade-v2.json")]
        ),
        .target(
            name: "CAxolotyZenohTestSupport",
            // Test-harness seam for publishing samples larger than the façade
            // receive bounds. Keep this module name and C entry points stable.
            dependencies: ["CZenohC"],
            path: "Tests/CAxolotyZenohTestSupport",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "CAxolotyZenohTests",
            dependencies: ["CAxolotyZenoh", "CAxolotyZenohTestSupport", "AxolotyZenohContract"],
            path: "ContractSuite"
        ),
        .testTarget(
            name: "AxolotyZenohCoreTests",
            dependencies: ["AxolotyZenohCore", "CAxolotyZenoh", "CAxolotyZenohTestSupport"],
            path: "Tests/AxolotyZenohCoreTests"
        ),
        .testTarget(
            name: "AxolotyZenohTests",
            dependencies: [
                "AxolotyZenoh",
                .product(name: "AxolotyTransportContractTestSupport", package: "Axoloty"),
                .product(name: "AxolotyProtocolTraceTestSupport", package: "Axoloty"),
                .product(name: "AxolotyTestBroker", package: "Axoloty"),
                .product(name: "AxolotyMQTT", package: "Axoloty"),
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyProtocol", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
            ],
            path: "Tests/AxolotyZenohTests"
        ),
    ]
)
