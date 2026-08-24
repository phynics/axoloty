// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import CompilerPluginSupport
import PackageDescription

/// Foundation-free synchronous runtime for the Embedded Swift profile.
let package = Package(
    name: "AxolotyStaticRuntime",
    products: [
        .library(name: "AxolotyStaticRuntime", targets: ["AxolotyStaticRuntime"]),
    ],
    dependencies: [
        .package(path: "../AxolotyProtocol"),
        .package(path: "../AxolotyObjectModel"),
        .package(path: "../AxolotyWire"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
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
                .product(name: "AxolotyWire", package: "AxolotyWire"),
                "AxolotyStaticRuntimeMacrosImplementation",
            ],
            path: "Sources/AxolotyStaticRuntime"
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
