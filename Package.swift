// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
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
        .library(
            name: "AxolotyIoRouting",
            targets: ["AxolotyIoRouting"]
        ),
        .library(
            name: "AxolotyStaticRuntime",
            targets: ["AxolotyStaticRuntime"]
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
        .package(url: "https://github.com/phynics/swift-json.git", exact: "2.5.3"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    ],
    targets: [
        .macro(
            name: "AxolotyStaticRuntimeMacrosImplementation",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            path: "Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntimeMacrosImplementation"
        ),
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
            name: "AxolotyIoRouting",
            dependencies: ["Axoloty", "AxolotyProtocol", "AxolotyObjectModel", "AxolotyWire"],
            path: "Packages/AxolotyIoRouting/Sources/AxolotyIoRouting"
        ),
        .target(
            name: "AxolotyStaticRuntime",
            dependencies: [
                "AxolotyProtocol",
                "AxolotyObjectModel",
                "AxolotyWire",
                "AxolotyStaticRuntimeMacrosImplementation",
            ],
            path: "Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime"
        ),
        .target(
            name: "Axoloty",
            dependencies: [
                "AxolotyWire",
                "AxolotyProtocol",
                "AxolotyObjectModel",
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(
                    name: "NIOSSL",
                    package: "swift-nio-ssl",
                    condition: .when(platforms: [.linux])
                ),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "IkigaJSON", package: "swift-json"),
            ],
            path: "Source",
            exclude: ["Runtime/AGENTS.md"],
            sources: [
                "Common/AxolotyError.swift",
                "Runtime/AxolotyRuntimeDefinition.swift",
                "Runtime/AxolotyRuntimeDefinition+IO.swift",
                "Runtime/AxolotyRuntime.swift",
                "Runtime/AxolotyRuntimeFacade.swift",
                "Runtime/MQTTExternalIoRoute.swift",
                "Runtime/RuntimeIO.swift",
                "Runtime/RuntimeLifecyclePayload.swift",
                "Runtime/ProtocolExecutor+Outbound.swift",
                "Runtime/RuntimeSupport.swift",
                "Runtime/MQTTBinding.swift",
                "Runtime/RuntimeMQTTClient.swift",
            ]
        ),
        .target(
            name: "AxolotyTestSupport",
            path: "Tests/AxolotyTestSupport"
        ),
        .testTarget(
            name: "AxolotyTests",
            dependencies: [
                "Axoloty",
                "AxolotyWire",
                "AxolotyProtocol",
                "AxolotyTestSupport",
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "IkigaJSON", package: "swift-json"),
            ],
            path: "Tests/AxolotyTests",
            resources: [
                .copy("ProtocolTrace/trace.schema.json"),
                .copy("ProtocolTrace/Fixtures/family-seeds.json"),
                .copy("WireCompatibility/Fixtures"),
            ]
        ),
        .testTarget(
            name: "AxolotyLiveWireTests",
            dependencies: [
                "Axoloty",
                "AxolotyWire",
                "AxolotyProtocol",
                "AxolotyTestSupport",
            ],
            path: "Tests/AxolotyLiveWireTests"
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
        .testTarget(
            name: "AxolotyIoRoutingTests",
            dependencies: ["AxolotyIoRouting", "Axoloty", "AxolotyProtocol", "AxolotyObjectModel", "AxolotyWire"],
            path: "Packages/AxolotyIoRouting/Tests/AxolotyIoRoutingTests"
        ),
        .testTarget(
            name: "AxolotyStaticRuntimeTests",
            dependencies: [
                "AxolotyStaticRuntime",
                "AxolotyProtocol",
                "AxolotyObjectModel",
                "AxolotyWire",
                "AxolotyStaticRuntimeMacrosImplementation",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Packages/AxolotyStaticRuntime/Tests/AxolotyStaticRuntimeTests"
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
        .executableTarget(
            name: "AxolotyResourceLeaseProbe",
            dependencies: ["AxolotyTooling"],
            path: "Tools/AxolotyResourceLeaseProbe"
        ),
        .testTarget(
            name: "AxolotyToolingTests",
            dependencies: ["AxolotyTooling", "AxolotyDeviceLeaseProbe", "AxolotyResourceLeaseProbe"],
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
            dependencies: ["Axoloty", "AxolotyInspectorCore", "AxolotyInspectorRuntime"],
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
                .product(name: "Logging", package: "swift-log"),
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
            dependencies: [
                "AxolotyMCP",
                "AxolotyTooling",
                "Axoloty",
                "AxolotyInspectorCore",
                "AxolotyInspectorRuntime",
            ],
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
            dependencies: ["AxolotyIoRouting"],
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
        // Warming regression probe for the static IO ownership primitives.
        // heaptrack compares short and long runs to require zero allocation
        // growth from macro dispatch and owning-action copy/visit operations.
        .executableTarget(
            name: "StaticIoOwnershipAllocation",
            dependencies: ["AxolotyStaticRuntime", "AxolotyProtocol", "AxolotyWire"],
            path: "Packages/AxolotyStaticRuntime/Benchmarks/StaticIoOwnershipAllocation"
        ),
    ],
    swiftLanguageModes: [.v6]
)
