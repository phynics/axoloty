// swift-tools-version: 6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "ObservedObjects",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(name: "Axoloty", path: "../.."),
    ],
    targets: [
        .target(
            name: "ObservedObjectsSpike",
            dependencies: [
                .product(name: "AxolotyObjectModel", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
            ]
        ),
        .testTarget(
            name: "ObservedObjectsSpikeTests",
            dependencies: [
                "ObservedObjectsSpike",
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyObjectModel", package: "Axoloty"),
                .product(name: "AxolotyProtocol", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
