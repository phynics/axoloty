// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "AxolotyObjectMacros",
    products: [
        .library(name: "AxolotyObjectMacros", targets: ["AxolotyObjectMacros"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    ],
    targets: [
        .macro(
            name: "AxolotyObjectMacrosImplementation",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "AxolotyObjectMacros",
            dependencies: ["AxolotyObjectMacrosImplementation"]
        ),
        .testTarget(
            name: "AxolotyObjectMacrosTests",
            dependencies: [
                "AxolotyObjectMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
