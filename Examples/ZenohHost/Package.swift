// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "ZenohHostExample",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ZenohHost", targets: ["ZenohHost"]),
    ],
    dependencies: [
        .package(name: "Axoloty", path: "../.."),
        .package(name: "AxolotyZenoh", path: "../../Packages/AxolotyZenoh"),
    ],
    targets: [
        .executableTarget(
            name: "ZenohHost",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyZenoh", package: "AxolotyZenoh"),
            ]
        ),
    ]
)
