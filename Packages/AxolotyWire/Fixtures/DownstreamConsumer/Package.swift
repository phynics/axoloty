// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Downstream fixture proving `AxolotyWire` resolves without the host runtime
/// dependency graph. This package depends ONLY on the local `AxolotyWire`
/// sub-package; resolving it must not fetch MQTTNIO, NIO, NIOSSL,
/// NIOTransportServices, Logging, or ErrorKit.
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
