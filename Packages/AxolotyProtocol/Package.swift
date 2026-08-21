// swift-tools-version:6.3
import PackageDescription

// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Standalone portable protocol foundation for the sealed Coaty Core Profile 3.
///
/// The package intentionally has one local dependency and no host runtime,
/// transport, logging, or Foundation dependency. The root package declares
/// the same target directly so host and Embedded Swift compile the same
/// production source set.
let package = Package(
    name: "AxolotyProtocol",
    products: [
        .library(name: "AxolotyProtocol", targets: ["AxolotyProtocol"]),
    ],
    dependencies: [
        .package(path: "../AxolotyWire"),
    ],
    targets: [
        .target(
            name: "AxolotyProtocol",
            dependencies: [
                .product(name: "AxolotyWire", package: "AxolotyWire"),
            ],
            path: "Sources/AxolotyProtocol"
        ),
        .testTarget(
            name: "AxolotyProtocolTests",
            dependencies: ["AxolotyProtocol"],
            path: "Tests/AxolotyProtocolTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
