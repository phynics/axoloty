// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import CompilerPluginSupport
import PackageDescription

/// Foundation-free synchronous runtime for the Embedded Swift profile.
let package = Package(
    name: "AxolotyStaticRuntime",
    // Apple platforms only: the portable sources use InlineArray and other
    // Swift 6 features available from the 26.0 SDKs, matching the root
    // package's floor. Linux and Embedded targets are unaffected.
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "AxolotyStaticRuntime", targets: ["AxolotyStaticRuntime"]),
    ],
    dependencies: [
        .package(path: "../AxolotyProtocol"),
        .package(path: "../AxolotyObjectModel"),
        .package(path: "../AxolotyWire"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .macro(
            name: "AxolotyStaticRuntimeMacrosImplementation",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            path: "Sources/AxolotyStaticRuntimeMacrosImplementation"
        ),
        .target(
            name: "AxolotyStaticRuntime",
            dependencies: [
                .product(name: "AxolotyProtocol", package: "AxolotyProtocol"),
                .product(name: "AxolotyObjectModel", package: "AxolotyObjectModel"),
                .product(name: "AxolotyWire", package: "AxolotyWire"),
                "AxolotyStaticRuntimeMacrosImplementation",
            ],
            path: "Sources/AxolotyStaticRuntime",
            // The embedded-core-consumer gate remains the enforcing portability check.
            swiftSettings: [.treatWarning("EmbeddedRestrictions", as: .warning)]
        ),
        .testTarget(
            name: "AxolotyStaticRuntimeTests",
            dependencies: [
                "AxolotyStaticRuntime",
                "AxolotyProtocol",
                "AxolotyObjectModel",
                "AxolotyWire",
                "AxolotyStaticRuntimeMacrosImplementation",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/AxolotyStaticRuntimeTests"
        ),
        .executableTarget(
            name: "StaticIoOwnershipAllocation",
            dependencies: ["AxolotyStaticRuntime", "AxolotyProtocol", "AxolotyWire"],
            path: "Benchmarks/StaticIoOwnershipAllocation"
        ),
    ],
    swiftLanguageModes: [.v6]
)
