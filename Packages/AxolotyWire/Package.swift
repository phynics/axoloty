// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Standalone, dependency-free wire codec package.
///
/// `AxolotyWire` is intentionally a separate package so a downstream
/// SwiftPM consumer can resolve and build it without fetching the host
/// runtime graph (MQTTNIO, NIO, NIOSSL, NIOTransportServices, Logging,
/// ErrorKit, IkigaJSON). The root Axoloty package consumes this package
/// via a local path dependency and re-exports its public symbols through
/// ``WireImportShim`` so existing `import Axoloty` clients keep working.
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
    targets: [
        .target(
            name: "AxolotyWire",
            path: "Sources/AxolotyWire"
        ),
    ],
    swiftLanguageModes: [.v6]
)
