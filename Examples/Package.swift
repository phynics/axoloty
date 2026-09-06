// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyExamples",
    products: [
        .executable(name: "HostRuntimeExample", targets: ["HostRuntimeExample"]),
        .executable(name: "WireExample", targets: ["WireExample"]),
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
    ]
)
