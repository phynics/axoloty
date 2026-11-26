// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyExamples",
    products: [
        .executable(name: "HostRuntimeExample", targets: ["HostRuntimeExample"]),
        .executable(name: "WireExample", targets: ["WireExample"]),
        .executable(name: "ObservedObjectsExample", targets: ["ObservedObjectsExample"]),
    ],
    dependencies: [
        .package(name: "Axoloty", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "HostRuntimeExample",
            dependencies: [.product(name: "Axoloty", package: "Axoloty")]
        ),
        .executableTarget(
            name: "WireExample",
            dependencies: [.product(name: "AxolotyWire", package: "Axoloty")]
        ),
        .executableTarget(
            name: "ObservedObjectsExample",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyObjectModel", package: "Axoloty"),
                .product(name: "AxolotyObservedObjects", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
            ]
        ),
    ]
)
