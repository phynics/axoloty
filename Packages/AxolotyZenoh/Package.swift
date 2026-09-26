// swift-tools-version:6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

// The Zenoh adapter is its own SwiftPM package so that no existing Axoloty
// product, and no build of the root package, resolves or links Zenoh. See
// docs/adr/0007-zenoh-adapter-package-boundary.md. The host C façade is the
// first target; the root package dependency and AxolotyZenohCore product arrive
// with #804, while the AxolotyZenoh product arrives with #807.
let package = Package(
    name: "AxolotyZenoh",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "AxolotyZenohCore", targets: ["AxolotyZenohCore"]),
    ],
    dependencies: [
        // ADR 0007 explicitly permits a path dependency on Axoloty; reusing
        // AxolotyWire's borrowed ByteSlice avoids a second byte-view contract.
        .package(name: "Axoloty", path: "../.."),
    ],
    targets: [
        // Consumes the pinned prebuilt zenoh-c archive through pkg-config; see
        // docs/adr/0006-zenoh-host-dependency-packaging.md. Provisioning
        // rewrites zenohc.pc's prefix and exports PKG_CONFIG_PATH.
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
            name: "CAxolotyZenohTestSupport",
            dependencies: ["CZenohC"],
            path: "Tests/CAxolotyZenohTestSupport",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "CAxolotyZenohTests",
            dependencies: ["CAxolotyZenoh", "CAxolotyZenohTestSupport"],
            path: "Tests/CAxolotyZenohTests"
        ),
        .testTarget(
            name: "AxolotyZenohCoreTests",
            dependencies: ["AxolotyZenohCore", "CAxolotyZenoh", "CAxolotyZenohTestSupport"],
            path: "Tests/AxolotyZenohCoreTests"
        ),
    ]
)
