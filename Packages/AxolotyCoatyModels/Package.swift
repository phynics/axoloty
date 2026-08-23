// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyCoatyModels",
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
            path: "Sources/AxolotyCoatyModels"
        ),
        .testTarget(
            name: "AxolotyCoatyModelsTests",
            dependencies: ["AxolotyCoatyModels", "AxolotyObjectModel", "AxolotyWire"],
            path: "Tests/AxolotyCoatyModelsTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
