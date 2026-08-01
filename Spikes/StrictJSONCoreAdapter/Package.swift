// swift-tools-version:6.3
import PackageDescription

// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
// Isolated issue #395 spike. Production Package.swift is intentionally untouched.

let package = Package(
    name: "StrictJSONCoreAdapterSpike",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: ".build/jsoncore-package")],
    targets: [
        .executableTarget(
            name: "StrictJSONCoreAdapterSpike",
            dependencies: [.product(name: "IkigaJSONCore", package: "jsoncore-package")],
            path: "Sources"
        )
    ]
)
