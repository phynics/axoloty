// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Standalone wire codec package with the pinned Foundation-free `_JSONCore` parser.
///
/// `AxolotyWire` is intentionally a separate package so a downstream
/// SwiftPM consumer can resolve and build it without fetching the host
/// runtime graph (MQTTNIO, NIO, NIOSSL, NIOTransportServices, Logging,
/// ErrorKit). The root Axoloty package declares the same target directly and
/// re-exports its public symbols through ``WireImportShim`` so existing
/// `import Axoloty` clients keep working.
///
/// See `docs/wire-extraction-boundaries.md` for the boundary contract.
let package = Package(
    name: "AxolotyWire",
    products: [
        .library(
            name: "AxolotyWire",
            targets: ["AxolotyWire"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/phynics/swift-json.git",
            exact: "2.5.3",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "AxolotyWire",
            dependencies: [
                .product(name: "IkigaJSONCore", package: "swift-json"),
            ],
            path: "Sources/AxolotyWire"
        ),
    ],
    swiftLanguageModes: [.v6]
)
