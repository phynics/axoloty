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
        .testTarget(
            name: "ObservedObjectsSpikeTests",
            dependencies: [
                .product(name: "AxolotyObservedObjects", package: "Axoloty"),
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyObjectModel", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
