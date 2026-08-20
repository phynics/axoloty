// swift-tools-version: 6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "BoundedPortableRuntimeMacroProbe",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [
        .library(name: "BoundedPortableRuntimeMacroProbe", targets: ["BoundedPortableRuntimeMacroProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    ],
    targets: [
        .macro(
            name: "BoundedPortableRuntimeMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "BoundedPortableRuntimeMacroProbe",
            dependencies: ["BoundedPortableRuntimeMacros"]
        ),
        .testTarget(
            name: "BoundedPortableRuntimeMacroProbeTests",
            dependencies: ["BoundedPortableRuntimeMacroProbe"]
        ),
    ]
)
