// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// swift-tools-version:6.3

import PackageDescription

let package = Package(
    name: "IkigaJSONCoreResolver",
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/swift-json.git", exact: "2.5.3"),
    ],
    targets: [
        .executableTarget(
            name: "Resolver",
            dependencies: [
                .product(name: "IkigaJSON", package: "swift-json"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
