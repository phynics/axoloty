// swift-tools-version:5.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "LegacyCoatySwiftScenarioRunner",
    platforms: [.macOS(.v10_13)],
    dependencies: [
        .package(
            name: "CoatySwift",
            url: "https://github.com/coatyio/coaty-swift.git",
            .revision("20a97b29832758fb771ac79fd5f7ae36cff69403")
        ),
    ],
    targets: [
        .target(
            name: "LegacyCoatySwiftScenarioRunner",
            dependencies: ["CoatySwift"]
        ),
    ]
)
