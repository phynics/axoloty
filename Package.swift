// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Axoloty",
    defaultLocalization: "en",
    platforms: [
            // Bumped from .v10_13/.v10 (T-005): mqtt-nio declares macOS(.v10_14)/
            // iOS(.v12) as its own minimum platforms.
            .macOS(.v10_14),
            .iOS(.v12),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CoatySwift",
            targets: ["CoatySwift"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.14.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/ReactiveX/RxSwift.git", from: "6.10.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "CoatySwift",
            dependencies: [
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "NIO", package: "swift-nio"),
                // Only needed directly by our own TLS configuration code on
                // non-Apple platforms (Linux); on Apple platforms TLS goes
                // through NIOTransportServices/Network.framework instead.
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux])),
                .product(name: "Logging", package: "swift-log"),
                "RxSwift"
            ],
            path: "Source"
        ),
        .testTarget(
            name: "CoatySwiftTests",
            dependencies: ["CoatySwift"],
            path: "Tests",
            exclude: [
                "TESTING.md",
                "Fuzzing/Artifacts",
                "Fuzzing/run-fuzz.sh",
                "Fuzzing/test-run-fuzz.sh",
                "Support",
                "WireCompatibility/Audit",
                "WireCompatibility/Capture",
                "WireCompatibility/CompatibilityMatrix.md",
                "WireCompatibility/Legacy",
                "WireCompatibility/Lifecycle/README.md",
                "WireCompatibility/Lifecycle/Live",
                "WireCompatibility/Live",
                "WireCompatibility/ReferenceAgents",
                "WireCompatibility/Reverse/Artifacts",
                "WireCompatibility/Reverse/README.md",
                "WireCompatibility/Reverse/coatyjs-advertise-consumer.js",
                "WireCompatibility/Reverse/run-axoloty-advertise.sh"
            ],
            resources: [
                .process("WireCompatibility/Fixtures")
            ]
        ),
    ]
)
