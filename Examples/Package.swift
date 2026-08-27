// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "AxolotyExamples",
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "HostRuntimeExample",
            dependencies: [.product(name: "Axoloty", package: "workspace")]
        ),
        .executableTarget(
            name: "WireExample",
            dependencies: [.product(name: "AxolotyWire", package: "workspace")]
        ),
    ]
)
