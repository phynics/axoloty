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
        .package(url: "https://github.com/phynics/swift-json.git", exact: "2.5.3"),
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
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "IkigaJSON", package: "swift-json"),
            ],
            path: "Source",
            exclude: ["Runtime/AGENTS.md"],
            sources: [
                "Common/AxolotyError.swift",
                "Runtime/AxolotyRuntimeDefinition.swift",
                "Runtime/AxolotyRuntime.swift",
                "Runtime/RuntimeLifecyclePayload.swift",
                "Runtime/ProtocolExecutor+Outbound.swift",
                "Runtime/RuntimeSupport.swift",
                "Runtime/MQTTBinding.swift",
                "Runtime/RuntimeMQTTClient.swift",
            ]
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
                "ProtocolTrace/README.md",
                "Support",
                // These retained tests are intentionally outside the current
                // target; some depend on host APIs no longer in the package.
                // Keep each source explicit so a new test cannot become silent.
                "Common/AnyCoatyObjectDecodableTests.swift",
                "Common/CoatyUUIDTests.swift",
                "Common/CodableJSONAnyTests.swift",
                "Communication/BonjourAddressSelectionTests.swift",
                "Communication/CallEventWireRoundTripTests.swift",
                "Communication/CallHandlerCorrelationTests.swift",
                "Communication/CommunicationSubscriptionCoordinatorTests.swift",
                "Communication/DiscoverResponderRegistrationTests.swift",
                "Communication/EventHubTransportTests.swift",
                "Communication/EventSnapshotMetadataTests.swift",
                "Communication/EventSnapshotSendabilityTests.swift",
                "Communication/IngressDeliveryQueueTests.swift",
                "Communication/IoAssociationRegistryTests.swift",
                "Communication/MQTTClientIdentityTests.swift",
                "Communication/MQTTNIOClientIsolationTests.swift",
                "Communication/MQTTNIOClientTests.swift",
                "Communication/OwnedRawJSONErrorTests.swift",
                "Communication/RequestResponseEventWireRoundTripTests.swift",
                "Communication/ReturnEventWireRoundTripTests.swift",
                "Communication/UnaryCallBrokerIntegrationTests.swift",
                "Concurrency/BroadcastTests.swift",
                "Controller/ObjectLifecycleControllerTests.swift",
                "Controller/ObjectLifecyclePublicationFailureTests.swift",
                "Fuzzing/DeterministicFuzzTests.swift",
                "IORouting/IoActorIoValueRoutingTests.swift",
                "IORouting/IoPublicationFailureTests.swift",
                "IORouting/IoRoutingTests.swift",
                "Infrastructure/ConfigurationBuilderTests.swift",
                "Infrastructure/ContainerBootstrapTests.swift",
                "Infrastructure/DecodingInvariantTests.swift",
                "Infrastructure/ErrorKitPolicyTests.swift",
                "Infrastructure/IkigaJSONDecoderSeamTests.swift",
                "Infrastructure/ObjectTypeRegistryTests.swift",
                "Infrastructure/PayloadCoderTests.swift",
                "Infrastructure/SerializationAuditTests.swift",
                "Infrastructure/TypedControllerOptionsTests.swift",
                "Infrastructure/WireImportSurfaceTests.swift",
                "Logging/DecentralizedLoggingTest.swift",
                "Logging/LogManagerTests.swift",
                "Model/FilterOperandTests.swift",
                "Model/ObjectJoinConditionTests.swift",
                "Model/ObjectMatcherTests.swift",
                "Model/RawJSONValueTests.swift",
                "Model/UserTests.swift",
                "SensorThings/CoatyTimeIntervalTests.swift",
                "SensorThings/PolygonTests.swift",
                "SensorThings/SensorSourcePublicationTests.swift",
                "SensorThings/SensorSourceQueryTypeTests.swift",
                "SensorThings/SensorSourceResponderReleaseTests.swift",
                "SensorThings/SensorThingsMocks.swift",
                "SensorThings/SensorThingsRelationQueryFilterTests.swift",
                "SensorThings/SensorThingsTests.swift",
                "SensorThings/SensorThingsWireRoundTripTests.swift",
                "Smoke/AxolotyTests.swift",
                "Testing/StandardErrorCapture.swift",
                "WireCodec/WireDifferentialTests.swift",
                "WireCompatibility/CoatyJsAdvertiseCaptureTests.swift",
                "WireCompatibility/CoatyJsCallReturnCaptureTests.swift",
                "WireCompatibility/CoatyJsCoreCaptureTests.swift",
                "WireCompatibility/CoatyJsDiscoverResolveCaptureTests.swift",
                "WireCompatibility/CoatyJsLastWillCaptureTests.swift",
                "WireCompatibility/CoatyJsQosScenarioCaptureTests.swift",
                "WireCompatibility/CoatyJsQueryRetrieveCaptureTests.swift",
                "WireCompatibility/CoatyJsUpdateCompleteCaptureTests.swift",
                "WireCompatibility/EmbeddedHostInteroperabilityTests.swift",
                "WireCompatibility/IO/AxolotyIoLiveTests.swift",
                "WireCompatibility/IO/AxolotyIoNegativeTests.swift",
                "WireCompatibility/IO/AxolotyIoValuePayloadTests.swift",
                "WireCompatibility/Legacy/LegacyCaptureFixtureTests.swift",
                "WireCompatibility/SensorThings/SensorThingsWireFixtureTests.swift",
                "WireCompatibility/WireFixtureTests.swift",
            ],
            sources: [
                "ProtocolTrace/ProtocolTrace.swift",
                "ProtocolTrace/ProtocolTraceCorpus.swift",
                "ProtocolTrace/ProtocolTraceTests.swift",
                "Infrastructure/TopicBuilderTests.swift",
                "Testing/AsyncWaiting.swift",
                "Testing/AsyncWaitingTests.swift",
                // Offline wire compatibility subjects are explicit here because
                // the target uses a source allow-list to keep broker and live
                // producer tests out of ordinary verification.
                "WireCompatibility/Lifecycle/LifecycleCompatibilityScenarioTests.swift",
                "WireCompatibility/WireCaptureFixture.swift",
                "WireCompatibility/WireCaptureFixtureTests.swift",
                // Live subjects remain available only to the explicit wire
                // capture plan, where the broker and peer controls exist.
                "WireCompatibility/IO/AxolotyIoAssociateTests.swift",
                "WireCompatibility/Lifecycle/AxolotyLifecycleSubjectTests.swift",
                "WireCompatibility/Reverse/AxolotyAdvertiseProducerTests.swift",
                "WireCompatibility/Reverse/AxolotyAdvertiseConsumerTests.swift",
                "WireCompatibility/Reverse/AxolotyCoreProducerTests.swift",
                "WireCompatibility/Reverse/AxolotyCoreConsumerTests.swift",
                "WireCompatibility/Reverse/AxolotyCoreRequestConsumerTests.swift",
                "WireCompatibility/Reverse/AxolotyUpdateCompleteConsumerTests.swift",
                "WireCompatibility/Reverse/AxolotyCallReturnConsumerTests.swift",
                "WireCompatibility/Reverse/ModernConsumerSupport.swift",
                "Runtime/AxolotyRuntimeTests.swift",
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
