// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

/// Standalone portable protocol foundation for the sealed Coaty Core Profile 3.
///
/// The package intentionally has one local dependency and no host runtime,
/// transport, logging, or Foundation dependency. The root package declares
/// the same target directly so host and Embedded Swift compile the same
/// production source set.
let package = Package(
    name: "AxolotyProtocol",
    // Apple platforms only: the portable sources use InlineArray and other
    // Swift 6 features available from the 26.0 SDKs, matching the root
    // package's floor. Linux and Embedded targets are unaffected.
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "AxolotyProtocol", targets: ["AxolotyProtocol"]),
    ],
    dependencies: [
        .package(path: "../AxolotyWire"),
        .package(path: "../AxolotyObjectModel"),
    ],
    targets: [
        .target(
            name: "AxolotyProtocol",
            dependencies: [
                .product(name: "AxolotyWire", package: "AxolotyWire"),
                .product(name: "AxolotyObjectModel", package: "AxolotyObjectModel"),
            ],
            path: "Sources/AxolotyProtocol"
        ),
        .testTarget(
            name: "AxolotyProtocolTests",
            dependencies: ["AxolotyProtocol", "AxolotyObjectModel"],
            path: "Tests/AxolotyProtocolTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
