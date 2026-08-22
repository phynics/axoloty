// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

/// Foundation-free synchronous runtime for the Embedded Swift profile.
let package = Package(
    name: "AxolotyStaticRuntime",
    products: [
        .library(name: "AxolotyStaticRuntime", targets: ["AxolotyStaticRuntime"]),
    ],
    dependencies: [
        .package(path: "../AxolotyProtocol"),
        .package(path: "../AxolotyWire"),
    ],
    targets: [
        .target(
            name: "AxolotyStaticRuntime",
            dependencies: [
                .product(name: "AxolotyProtocol", package: "AxolotyProtocol"),
                .product(name: "AxolotyWire", package: "AxolotyWire"),
            ],
            path: "Sources/AxolotyStaticRuntime"
        ),
        .testTarget(
            name: "AxolotyStaticRuntimeTests",
            dependencies: ["AxolotyStaticRuntime", "AxolotyProtocol", "AxolotyWire"],
            path: "Tests/AxolotyStaticRuntimeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
