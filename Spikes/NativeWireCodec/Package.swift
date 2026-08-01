// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// swift-tools-version:6.3

import PackageDescription

let package = Package(
    name: "NativeWireCodecSpike",
    dependencies: [
        .package(path: "../../Packages/AxolotyWire"),
    ],
    targets: [
        .executableTarget(
            name: "NativeWireCodecProbe",
            dependencies: [
                .product(name: "AxolotyWire", package: "AxolotyWire"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
