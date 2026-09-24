// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyCoatyModels",
    // Apple platforms only: the portable sources use InlineArray and other
    // Swift 6 features available from the 26.0 SDKs, matching the root
    // package's floor. Linux and Embedded targets are unaffected.
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "AxolotyCoatyModels", targets: ["AxolotyCoatyModels"]),
    ],
    dependencies: [
        .package(path: "../AxolotyObjectModel"),
        .package(path: "../AxolotyWire"),
    ],
    targets: [
        .target(
            name: "AxolotyCoatyModels",
            dependencies: ["AxolotyObjectModel"],
            path: "Sources/AxolotyCoatyModels",
            // The embedded-core-consumer gate remains the enforcing portability check.
            swiftSettings: [.treatWarning("EmbeddedRestrictions", as: .warning)]
        ),
        .testTarget(
            name: "AxolotyCoatyModelsTests",
            dependencies: ["AxolotyCoatyModels", "AxolotyObjectModel", "AxolotyWire"],
            path: "Tests/AxolotyCoatyModelsTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
