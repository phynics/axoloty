// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// swift-tools-version:6.3

import PackageDescription

let package = Package(
    name: "IkigaJSONCoreBackendSpike",
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/swift-json.git", exact: "2.5.3"),
    ],
    targets: [
        .executableTarget(
            name: "IkigaJSONCoreBackendProbe",
            dependencies: [
                // Swift 6.3 selects swift-json's Package@swift-6.2.3.swift,
                // which omits the otherwise-declared IkigaJSONCore product.
                // This public product keeps resolution reproducible while the
                // probe compiles _JSONCore directly to model a corrected
                // upstream manifest.
                .product(name: "IkigaJSON", package: "swift-json"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
