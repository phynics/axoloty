// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Standalone wire codec package with the pinned Foundation-free `_JSONCore` parser.
///
/// `AxolotyWire` is intentionally a separate package so a downstream
/// SwiftPM consumer can build it without host runtime targets. Its tested
/// resolved package closure is exactly `axolotywire`, `swift-json`,
/// `swift-nio`, `swift-atomics`, `swift-collections`, and `swift-system`;
/// `swift-nio` is resolution-only. The root Axoloty package declares the same
/// target directly and re-exports its public symbols through
/// ``WireImportShim`` so existing `import Axoloty` clients keep working.
///
/// See the repository `ARCHITECTURE.md` for the boundary contract.
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
        .testTarget(
            name: "AxolotyWireTests",
            dependencies: ["AxolotyWire"],
            path: "Tests/AxolotyWireTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
