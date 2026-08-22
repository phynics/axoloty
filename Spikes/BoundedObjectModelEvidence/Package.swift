// swift-tools-version: 6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "BoundedObjectModelEvidence",
    products: [
        .executable(name: "bounded-object-model-probe", targets: ["BoundedObjectModelProbe"]),
    ],
    dependencies: [
        .package(path: "../../Packages/AxolotyObjectModel"),
        .package(path: "../../Packages/AxolotyWire"),
    ],
    targets: [
        .executableTarget(
            name: "BoundedObjectModelProbe",
            dependencies: [
                .product(name: "AxolotyObjectModel", package: "AxolotyObjectModel"),
                .product(name: "AxolotyWire", package: "AxolotyWire"),
            ],
            path: "Sources/BoundedObjectModelProbe"
        ),
        .testTarget(
            name: "BoundedObjectModelEvidenceTests",
            dependencies: [
                .product(name: "AxolotyObjectModel", package: "AxolotyObjectModel"),
                .product(name: "AxolotyWire", package: "AxolotyWire"),
            ],
            path: "Tests/BoundedObjectModelEvidenceTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
