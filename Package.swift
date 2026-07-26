// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Axoloty",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(
            name: "Axoloty",
            targets: ["Axoloty"]
        ),
    ],
    dependencies: [
        .package(path: "Packages/AxolotyWire"),
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit.git", exact: "1.2.1"),
        .package(url: "https://github.com/orlandos-nl/swift-json.git", exact: "2.5.3"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Axoloty",
            dependencies: [
                .product(name: "AxolotyWire", package: "AxolotyWire"),
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux])),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "IkigaJSON", package: "swift-json"),
            ],
            path: "Source"
        ),
        .testTarget(
            name: "AxolotyTests",
            dependencies: [
                "Axoloty",
                .product(name: "AxolotyWire", package: "AxolotyWire"),
                .product(name: "IkigaJSON", package: "swift-json"),
            ],
            path: "Tests",
            exclude: [
                "AxolotyWire",
                "TESTING.md",
                "Fuzzing/Artifacts",
                "Fuzzing/run-fuzz.sh",
                "Fuzzing/test-run-fuzz.sh",
                "Support",
                "WireCompatibility/Audit",
                "WireCompatibility/Capture",
                "WireCompatibility/CompatibilityMatrix.md",
                "WireCompatibility/IO/coatyjs-io-runner.js",
                "WireCompatibility/IO/Live",
                "WireCompatibility/Legacy/macOS-runner",
                "WireCompatibility/Legacy/README.md",
                "WireCompatibility/Legacy/run_capture_on_macos.sh",
                "WireCompatibility/Lifecycle/README.md",
                "WireCompatibility/Lifecycle/Live",
                "WireCompatibility/Live",
                "WireCompatibility/ReferenceAgents",
                "WireCompatibility/tool",
                "WireCompatibility/Reverse/Artifacts",
                "WireCompatibility/Reverse/README.md",
                "WireCompatibility/Reverse/coatyjs-advertise-consumer.js",
                "WireCompatibility/Reverse/coatyjs-core-consumer.js",
                "WireCompatibility/Reverse/run-axoloty-advertise.sh",
                "WireCompatibility/Reverse/run-axoloty-core.sh",
                "WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh",
                "WireCompatibility/Reverse/run-coatyjs-to-axoloty-core.sh",
                "WireCompatibility/Reverse/coatyjs-core-requester.js",
                "WireCompatibility/Reverse/coatyjs-to-modern-requester.js",
            ],
            resources: [
                .process("WireCompatibility/Fixtures"),
            ]
        ),
        .testTarget(
            name: "AxolotyWireTests",
            dependencies: [
                .product(name: "AxolotyWire", package: "AxolotyWire"),
            ],
            path: "Tests/AxolotyWire"
        ),
    ],
    swiftLanguageModes: [.v6]
)
