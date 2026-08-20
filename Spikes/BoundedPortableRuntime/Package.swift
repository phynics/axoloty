// swift-tools-version: 6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "BoundedPortableRuntime",
    products: [
        .library(name: "BoundedPortableRuntime", targets: ["BoundedPortableRuntime"]),
        .executable(name: "bounded-runtime-probe", targets: ["BoundedPortableRuntimeProbe"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "BoundedPortableRuntime", path: "Sources/BoundedPortableRuntime"),
        .executableTarget(
            name: "BoundedPortableRuntimeProbe",
            dependencies: ["BoundedPortableRuntime"],
            path: "Sources/BoundedPortableRuntimeProbe"
        ),
        .testTarget(
            name: "BoundedPortableRuntimeTests",
            dependencies: ["BoundedPortableRuntime"],
            path: "Tests/BoundedPortableRuntimeTests"
        ),
    ]
)
