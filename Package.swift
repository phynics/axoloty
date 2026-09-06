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
            name: "AxolotyMQTT",
            targets: ["AxolotyMQTT"]
        ),
        .library(
            name: "AxolotyIoRouting",
            targets: ["AxolotyIoRouting"]
        ),
        .library(
            name: "AxolotySensorThingsModel",
            targets: ["AxolotySensorThingsModel"]
        ),
        .library(
            name: "AxolotySensorThings",
            targets: ["AxolotySensorThings"]
        ),
        .library(
            name: "AxolotyStaticRuntime",
            targets: ["AxolotyStaticRuntime"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit.git", exact: "1.2.1"),
        .package(url: "https://github.com/phynics/swift-json.git", exact: "2.5.3"),
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
        // SensorThings schemas and JSON shaping. Depends only on the portable
        // object model, so a consumer that encodes or decodes SensorThings
        // values needs no runtime.
        .target(
            name: "AxolotySensorThingsModel",
            dependencies: ["AxolotyObjectModel", "AxolotyWire"],
            path: "Packages/AxolotySensorThings/Sources/AxolotySensorThingsModel"
        ),
        .target(
            name: "AxolotySensorThings",
            dependencies: ["Axoloty", "AxolotySensorThingsModel", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyWire"],
            path: "Packages/AxolotySensorThings/Sources/AxolotySensorThings"
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
                .product(name: "ErrorKit", package: "ErrorKit"),
            ],
            path: "Source",
            exclude: ["Runtime/AGENTS.md"],
            sources: [
                "Common/AxolotyError.swift",
                "Runtime/AxolotyRuntimeConfiguration.swift",
                "Runtime/AxolotyRuntimeEvents.swift",
                "Runtime/AxolotyRuntimeOperations.swift",
                "Runtime/AxolotyRuntimeDiagnostics.swift",
                "Runtime/AxolotyRuntimeTransport.swift",
                "Runtime/AxolotyRuntimeHandlers.swift",
                "Runtime/AxolotyRuntimeDefinition.swift",
                "Runtime/AxolotyRuntimeDefinition+IO.swift",
                "Runtime/AxolotyRuntime.swift",
                "Runtime/AxolotyRuntimeFacade.swift",
                "Runtime/IO/ExternalIoRoute.swift",
                "Runtime/IO/RuntimeIO.swift",
                "Runtime/IO/RuntimeTypedIoState.swift",
                "Runtime/RuntimeLifecyclePayload.swift",
                "Runtime/Executor/ProtocolExecutor+Outbound.swift",
                "Runtime/Executor/ProtocolExecutor+Conformance.swift",
                "Runtime/Executor/ProtocolExecutor+Handlers.swift",
                "Runtime/RuntimeModules.swift",
                "Runtime/RuntimeSupport.swift",
                "Runtime/CoatyRoute.swift",
            ]
        ),
        // The MQTT transport adapter. Every MQTT and NIO dependency lives
        // here, so a consumer of the runtime alone resolves none of them.
        .target(
            name: "AxolotyMQTT",
            dependencies: [
                "Axoloty",
                "AxolotyProtocol",
                "AxolotyWire",
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
            ],
            path: "Packages/AxolotyMQTT/Sources/AxolotyMQTT"
        ),
        .testTarget(
            name: "AxolotyMQTTTests",
            dependencies: ["AxolotyMQTT", "Axoloty", "AxolotyProtocol", "AxolotyWire"],
            path: "Packages/AxolotyMQTT/Tests/AxolotyMQTTTests"
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
                "AxolotyStaticRuntime",
                "AxolotyTestSupport",
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "IkigaJSON", package: "swift-json"),
            ],
            path: "Tests/AxolotyTests",
            resources: [
                .copy("ProtocolTrace/trace.schema.json"),
                .copy("ProtocolTrace/Fixtures/family-seeds.json"),
                .process("WireCompatibility/Fixtures"),
            ]
        ),
        .testTarget(
            name: "AxolotyLiveWireTests",
            dependencies: [
                "AxolotyMQTT",
                "Axoloty",
                "AxolotyWire",
                "AxolotyProtocol",
                "AxolotyTestSupport",
            ],
            path: "Tests/AxolotyLiveWireTests"
        ),
        .testTarget(
            name: "AxolotyWireTests",
            dependencies: ["AxolotyWire"],
            path: "Packages/AxolotyWire/Tests/AxolotyWireTests"
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
            name: "AxolotySensorThingsTests",
            dependencies: ["AxolotySensorThingsModel", "AxolotySensorThings", "Axoloty", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyWire"],
            path: "Packages/AxolotySensorThings/Tests/AxolotySensorThingsTests"
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
        // MQTT object inspector. The core target has no product-runtime
        // dependencies; the runtime target adds Axoloty-backed session and
        // application logic; the CLI target adds the entry point.
        // Axoloty MCP server. Depends on the inspector runtime for broker
        // connectivity and the official MCP Swift SDK for protocol.
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
            dependencies: ["AxolotySensorThingsModel", "AxolotySensorThings"],
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
