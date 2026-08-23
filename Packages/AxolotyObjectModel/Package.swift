// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyObjectModel",
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
