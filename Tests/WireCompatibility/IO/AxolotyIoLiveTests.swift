// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Live env-gated tests for IO scenarios requiring a broker and a pinned
/// CoatyJS 2.4.0 reference agent.
///
/// Each test is disabled by default and enabled only when the corresponding
/// `WIRE_IO_*_LIVE` environment variable is set to `"1"`. The live shell
/// runners in `IO/Live/` set these variables and orchestrate the CoatyJS
/// container alongside the Swift test process.
///
/// Scenarios:
/// - Raw IoValue (scenario 3): CoatyJS raw-source publishes binary payload
///   containing NUL byte and invalid UTF-8.
/// - External route (scenario 4): CoatyJS external-source publishes JSON
///   IoValues on a deterministic non-Coaty route.
@MainActor
struct AxolotyIoLiveTests {

    // MARK: - Raw IoValue: JS -> modern (Axoloty is the actor)

    /// CoatyJS 2.4.0 acts as raw-source (useRawIoValues=true) and Axoloty is
    /// the actor. CoatyJS publishes an Associate and a raw binary IoValue
    /// containing a NUL byte (0x00) and invalid UTF-8 (0xFF, 0xFE). Axoloty
    /// must associate, receive the raw bytes without UTF-8 decoding, and
    /// acknowledge.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_RAW_JS_TO_MODERN_LIVE"] == "1"))
    func decodesRawIoValueFromCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let contextName = environment["IO_CONTEXT_NAME"] ?? "wire-compat-io-context-1"
        let actorId = try #require(CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let actor = IoActor(
            valueType: "com.coaty.test.WireIoValue",
            useRawIoValues: true,
            name: "wire-compat-io-actor-1",
            objectId: actorId
        )

        let communication = CommunicationOptions(
            namespace: namespace,
            mqttClientOptions: MQTTClientOptions(host: host, port: port),
            shouldAutoStart: false
        )
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(
                common: CommonOptions(ioContextNodes: [
                    contextName: IoNodeDefinition(ioSources: [], ioActors: [actor], characteristics: nil),
                ]),
                communication: communication
            )
        )
        defer { container.shutdown() }

        let cm = try #require(container.communicationManager)
        try await container.startAndWaitUntilReady()

        var stateIterator = (await cm.observeIoStateStream(ioPoint: actor)).makeAsyncIterator()
        var valueIterator = (await cm.observeIoValueStream()).makeAsyncIterator()

        print("{\"state\":\"ready\",\"scenario\":\"io-raw-js-to-modern\"}")

        // Await association from CoatyJS raw-source.
        var state: IoStateEventSnapshot = try await nextValue(&stateIterator, timeout: .seconds(45))
        while !state.hasAssociations {
            state = try await nextValue(&stateIterator, timeout: .seconds(45))
        }
        #expect(state.hasAssociations == true)

        // Expect the raw payload CoatyJS publishes:
        // Buffer.from([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x41, 0x42])
        let expectedRaw: [UInt8] = [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x41, 0x42]
        let value: IoValueEventSnapshot = try await nextValue(&valueIterator, timeout: .seconds(30))
        #expect(value.payload == expectedRaw)

        print("{\"state\":\"ack\",\"scenario\":\"io-raw-js-to-modern\"}")
    }

    // MARK: - Raw IoValue: modern -> JS (Axoloty is the source)

    /// Axoloty acts as IO router + IO source with useRawIoValues=true. It
    /// associates a deterministic source+actor on a generated IOV route,
    /// publishes a raw IoValue (containing NUL byte and invalid UTF-8), then
    /// disassociates. A pinned CoatyJS 2.4.0 actor with IO_RAW=1 (started
    /// by the live runner) must decode the Associate, subscribe to the route,
    /// receive the raw bytes, and acknowledge.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_RAW_MODERN_TO_JS_LIVE"] == "1"))
    func publishesRawIoValueForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let contextName = environment["IO_CONTEXT_NAME"] ?? "wire-compat-io-context-1"

        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let actorId = try #require(CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
            useRawIoValues: true,
            name: "wire-compat-io-source-1",
            objectId: sourceId
        )

        let communication = CommunicationOptions(
            namespace: namespace,
            mqttClientOptions: MQTTClientOptions(host: host, port: port),
            shouldAutoStart: false
        )
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(
                common: CommonOptions(ioContextNodes: [
                    contextName: IoNodeDefinition(ioSources: [source], ioActors: [], characteristics: nil),
                ]),
                communication: communication
            )
        )
        defer { container.shutdown() }

        let cm = try #require(container.communicationManager)
        try await container.startAndWaitUntilReady()

        let route = cm.createIoRoute(ioSource: source)
        print("{\"state\":\"ready\",\"scenario\":\"io-raw-modern-to-js\",\"route\":\"\(route)\"}")

        // Publish Associate for the raw source.
        try cm.publishAssociate(event: AssociateEvent.with(
            ioContextName: contextName,
            ioSourceId: sourceId,
            ioActorId: actorId,
            associatingRoute: route,
            isExternalRoute: false,
            updateRate: 250
        ))
        try await _Concurrency.Task.sleep(for: .milliseconds(1500))

        // Publish raw IoValue (NUL byte + invalid UTF-8).
        let rawPayload: [UInt8] = [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x41, 0x42]
        let event = try IoValueEvent.with(ioSource: source, value: rawPayload, options: [:])
        cm.publishIoValue(event: event)
        print("{\"state\":\"published-iovalue\",\"scenario\":\"io-raw-modern-to-js\",\"route\":\"\(route)\"}")

        try await _Concurrency.Task.sleep(for: .milliseconds(1500))

        // Disassociate.
        try cm.publishAssociate(event: AssociateEvent.with(
            ioContextName: contextName,
            ioSourceId: sourceId,
            ioActorId: actorId,
            associatingRoute: nil
        ))
        try await _Concurrency.Task.sleep(for: .milliseconds(1000))
    }

    // MARK: - External route: JS -> modern (Axoloty is the actor)

    /// CoatyJS 2.4.0 acts as external-source, associating on a deterministic
    /// non-Coaty route (`external/wire-compat-v1/io-external-1`) and
    /// publishing JSON IoValues there. Axoloty is the IoActor on that
    /// external route and must associate, receive the values, and acknowledge.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_EXT_JS_TO_MODERN_LIVE"] == "1"))
    func decodesExternalRouteIoValueFromCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let contextName = environment["IO_CONTEXT_NAME"] ?? "wire-compat-io-context-1"
        let actorId = try #require(CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let actor = IoActor(
            valueType: "com.coaty.test.WireIoValue",
            name: "wire-compat-io-actor-1",
            objectId: actorId
        )

        let communication = CommunicationOptions(
            namespace: namespace,
            mqttClientOptions: MQTTClientOptions(host: host, port: port),
            shouldAutoStart: false
        )
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(
                common: CommonOptions(ioContextNodes: [
                    contextName: IoNodeDefinition(ioSources: [], ioActors: [actor], characteristics: nil),
                ]),
                communication: communication
            )
        )
        defer { container.shutdown() }

        let cm = try #require(container.communicationManager)
        try await container.startAndWaitUntilReady()

        var stateIterator = (await cm.observeIoStateStream(ioPoint: actor)).makeAsyncIterator()
        var valueIterator = (await cm.observeIoValueStream()).makeAsyncIterator()

        print("{\"state\":\"ready\",\"scenario\":\"io-ext-js-to-modern\"}")

        // Await association from CoatyJS external-source.
        var state: IoStateEventSnapshot = try await nextValue(&stateIterator, timeout: .seconds(45))
        while !state.hasAssociations {
            state = try await nextValue(&stateIterator, timeout: .seconds(45))
        }
        #expect(state.hasAssociations == true)

        // The external-source publishes JSON IoValues on the external route.
        let value: IoValueEventSnapshot = try await nextValue(&valueIterator, timeout: .seconds(30))
        #expect(!value.payload.isEmpty)

        print("{\"state\":\"ack\",\"scenario\":\"io-ext-js-to-modern\"}")
    }
}
