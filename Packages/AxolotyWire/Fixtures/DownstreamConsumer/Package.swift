// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Downstream fixture proving `AxolotyWire` builds without host runtime
/// targets. This package depends only on the local `AxolotyWire` sub-package;
/// its tested resolved package closure is exactly `axolotywire`, `swift-json`,
/// `swift-nio`, `swift-atomics`, `swift-collections`, and `swift-system`.
/// `swift-nio` is resolution-only and must not be built or linked.
let package = Package(
    name: "DownstreamConsumer",
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "DownstreamConsumer",
            dependencies: [
                .product(name: "AxolotyWire", package: "AxolotyWire"),
            ]
        ),
    ]
)
