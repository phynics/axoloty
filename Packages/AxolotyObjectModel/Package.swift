// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyObjectModel",
    // Apple platforms only: the portable sources use InlineArray and other
    // Swift 6 features available from the 26.0 SDKs, matching the root
    // package's floor. Linux and Embedded targets are unaffected.
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "AxolotyObjectModel", targets: ["AxolotyObjectModel"]),
    ],
    dependencies: [
        .package(path: "../AxolotyWire"),
    ],
    targets: [
        .target(
            name: "AxolotyObjectModel",
            dependencies: [.product(name: "AxolotyWire", package: "AxolotyWire")],
            path: "Sources/AxolotyObjectModel"
        ),
        .testTarget(
            name: "AxolotyObjectModelTests",
            dependencies: ["AxolotyObjectModel"],
            path: "Tests/AxolotyObjectModelTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
