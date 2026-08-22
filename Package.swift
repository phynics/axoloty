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
        .library(
            name: "AxolotyWire",
            targets: ["AxolotyWire"]
        ),
        .library(
            name: "AxolotyProtocol",
            targets: ["AxolotyProtocol"]
        ),
        .library(
            name: "AxolotyObjectModel",
            targets: ["AxolotyObjectModel"]
        ),
        .library(
            name: "AxolotyCoatyModels",
            targets: ["AxolotyCoatyModels"]
        ),
        .executable(
            name: "axoloty-tool",
            targets: ["AxolotyCLI"]
        ),
        .executable(
            name: "ax",
            targets: ["AxolotyCLI"]
        ),
        .executable(
            name: "axoloty-inspect",
            targets: ["AxolotyInspectorCLI"]
        ),
        .executable(
            name: "axoloty-mcp",
            targets: ["AxolotyMCPServer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit.git", exact: "1.2.1"),
        .package(
            url: "https://github.com/phynics/swift-json.git",
            exact: "2.5.3"
        ),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AxolotyWire",
            dependencies: [
                .product(name: "IkigaJSONCore", package: "swift-json"),
            ],
            path: "Packages/AxolotyWire/Sources/AxolotyWire"
        ),
        .target(
            name: "AxolotyProtocol",
            dependencies: ["AxolotyWire", "AxolotyObjectModel"],
            path: "Packages/AxolotyProtocol/Sources/AxolotyProtocol"
        ),
        .target(
            name: "AxolotyObjectModel",
            dependencies: ["AxolotyWire"],
            path: "Packages/AxolotyObjectModel/Sources/AxolotyObjectModel"
        ),
        .target(
            name: "AxolotyCoatyModels",
            dependencies: ["AxolotyObjectModel"],
            path: "Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels"
        ),
        .target(
            name: "Axoloty",
            dependencies: [
                "AxolotyWire",
                "AxolotyProtocol",
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
                "AxolotyWire",
                "AxolotyProtocol",
                .product(name: "IkigaJSON", package: "swift-json"),
            ],
            path: "Tests",
            exclude: [
                "AGENTS.md",
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
                "WireCompatibility/Legacy/run-modern-to-legacy.sh",
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
                "ProtocolTrace/README.md",
            ],
            resources: [
                .copy("ProtocolTrace/trace.schema.json"),
                .copy("ProtocolTrace/Fixtures/family-seeds.json"),
                .process("WireCompatibility/Fixtures"),
            ]
        ),
        .testTarget(
            name: "AxolotyWireTests",
            dependencies: [
                "AxolotyWire",
                "AxolotyProtocol",
            ],
            path: "Tests/AxolotyWire"
        ),
        .testTarget(
            name: "AxolotyProtocolTests",
            dependencies: ["AxolotyProtocol", "AxolotyWire"],
            path: "Packages/AxolotyProtocol/Tests/AxolotyProtocolTests"
        ),
        .testTarget(
            name: "AxolotyObjectModelTests",
            dependencies: ["AxolotyObjectModel", "AxolotyWire"],
            path: "Packages/AxolotyObjectModel/Tests/AxolotyObjectModelTests"
        ),
        .testTarget(
            name: "AxolotyCoatyModelsTests",
            dependencies: ["AxolotyCoatyModels", "AxolotyObjectModel", "AxolotyWire"],
            path: "Packages/AxolotyCoatyModels/Tests/AxolotyCoatyModelsTests"
        ),
        // The tooling control plane. It intentionally has no product-runtime
        // dependencies so it can bootstrap repository workflows independently.
        .executableTarget(
            name: "AxolotyCLI",
            dependencies: ["AxolotyTooling"],
            path: "Tools/axoloty-tool"
        ),
        .target(
            name: "AxolotyProcessLauncher",
            path: "Tools/AxolotyProcessLauncher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AxolotyTooling",
            dependencies: ["AxolotyProcessLauncher"],
            path: "Tools/AxolotyTooling",
            resources: [.copy("Resources/test-tiers.json")]
        ),
        .executableTarget(
            name: "AxolotyDeviceLeaseProbe",
            dependencies: ["AxolotyTooling"],
            path: "Tools/AxolotyDeviceLeaseProbe"
        ),
        .testTarget(
            name: "AxolotyToolingTests",
            dependencies: ["AxolotyTooling", "AxolotyDeviceLeaseProbe"],
            path: "Tools/AxolotyToolingTests",
            resources: [.copy("Fixtures/legacy-check-plan-v1.json")]
        ),
        // MQTT object inspector. The core target has no product-runtime
        // dependencies; the runtime target adds Axoloty-backed session and
        // application logic; the CLI target adds the entry point.
        .target(
            name: "AxolotyInspectorCore",
            path: "Tools/AxolotyInspectorCore"
        ),
        .target(
            name: "AxolotyInspectorRuntime",
            dependencies: ["Axoloty", "AxolotyInspectorCore"],
            path: "Tools/AxolotyInspectorRuntime"
        ),
        .executableTarget(
            name: "AxolotyInspectorCLI",
            dependencies: ["Axoloty", "AxolotyInspectorCore", "AxolotyInspectorRuntime"],
            path: "Tools/axoloty-inspect"
        ),
        .testTarget(
            name: "AxolotyInspectorCoreTests",
            dependencies: ["AxolotyInspectorCore"],
            path: "Tools/AxolotyInspectorCoreTests"
        ),
        .testTarget(
            name: "AxolotyInspectorRuntimeTests",
            dependencies: ["AxolotyInspectorRuntime", "AxolotyInspectorCore"],
            path: "Tools/AxolotyInspectorRuntimeTests"
        ),
        .testTarget(
            name: "AxolotyInspectorCLITests",
            dependencies: ["Axoloty", "AxolotyInspectorCore", "AxolotyInspectorRuntime", "AxolotyInspectorCLI"],
            path: "Tools/AxolotyInspectorCLITests"
        ),
        // Axoloty MCP server. Depends on the inspector runtime for broker
        // connectivity and the official MCP Swift SDK for protocol.
        .target(
            name: "AxolotyMCP",
            dependencies: [
                "Axoloty",
                "AxolotyInspectorCore",
                "AxolotyInspectorRuntime",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tools/AxolotyMCP"
        ),
        .testTarget(
            name: "AxolotyMCPTests",
            dependencies: ["AxolotyMCP", "AxolotyMCPServer", "AxolotyTooling"],
            path: "Tools/AxolotyMCPTests"
        ),
        .executableTarget(
            name: "AxolotyMCPServer",
            dependencies: ["AxolotyMCP", "AxolotyTooling", "Axoloty", "AxolotyInspectorCore", "AxolotyInspectorRuntime"],
            path: "Tools/axoloty-mcp"
        ),
        // Build-only release consumers for binary-size and dependency-closure
        // benchmarking (issue #299). Not shipped as products — they exist so
        // `make benchmark-size` can measure the linked binary size and verify
        // the AxolotyWire consumer pulls no host runtime dependencies.
        .executableTarget(
            name: "AxolotyWireConsumer",
            dependencies: [
                "AxolotyWire",
            ],
            path: "Benchmarks/Consumers/AxolotyWireConsumer"
        ),
        .executableTarget(
            name: "AxolotyConsumer",
            dependencies: ["Axoloty"],
            path: "Benchmarks/Consumers/AxolotyConsumer"
        ),
        // Additional release consumers for binary-size attribution (issue
        // #353). Each anchors a different subsystem so `make benchmark-size`
        // can measure its incremental contribution to binary size.
        .executableTarget(
            name: "CommunicationConsumer",
            dependencies: ["Axoloty"],
            path: "Benchmarks/Consumers/CommunicationConsumer"
        ),
        .executableTarget(
            name: "IoRoutingConsumer",
            dependencies: ["Axoloty"],
            path: "Benchmarks/Consumers/IoRoutingConsumer"
        ),
        .executableTarget(
            name: "SensorThingsConsumer",
            dependencies: ["Axoloty"],
            path: "Benchmarks/Consumers/SensorThingsConsumer"
        ),
        // Release-only wire benchmark executable (issue #300). Measures
        // p50/p95 latency for topic parse, DTO decode/encode, borrowed-message
        // validation, and combined parse-decode on every corpus case.
        .executableTarget(
            name: "WireBenchmark",
            dependencies: [
                "AxolotyWire",
                "AxolotyProtocol",
            ],
            path: "Benchmarks/WireBenchmark"
        ),
        // Dedicated host allocation-regression probe for the borrowed decode +
        // static routing hot path (issue #490). Wrapped in an instrumentation
        // (heaptrack) by check-benchmark-wire-allocation.sh to assert the
        // documented exact-zero steady-state allocation contract.
        .executableTarget(
            name: "WireAllocation",
            dependencies: [
                "AxolotyWire",
                "AxolotyProtocol",
            ],
            path: "Benchmarks/WireAllocation"
        ),
    ],
    swiftLanguageModes: [.v6]
)
