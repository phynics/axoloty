// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// swift-tools-version:6.3

import PackageDescription

let package = Package(
    name: "IkigaJSONCoreConsumer",
    dependencies: [
        .package(path: "../swift-json", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "CoreConsumer",
            dependencies: [
                .product(name: "IkigaJSONCore", package: "swift-json"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
