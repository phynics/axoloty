// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// IO routing wire-compatibility evidence for T-021 scenario 1 (Associate
/// generated route) and scenario 2 (JSON IoValue).
///
/// The offline cases assert the exact wire format Axoloty puts on the wire and
/// the way it decodes a pinned CoatyJS 2.4.0 peer's payloads, so the
/// compatibility facts are captured deterministically in the PR-tier test run
/// regardless of whether a live broker is available. The live, env-gated case
/// exercises the modern -> JS direction end to end.
///
/// Findings recorded here feed the keep/diverge/remove decisions in
/// `Tests/WireCompatibility/Audit/IOAndSensorThingsDecisions.md`.
@MainActor
struct AxolotyIoAssociateTests {

    // MARK: - Deterministic wire-format evidence (PR tier, no broker)

    /// The Associate event for a generated route carries the source/actor IDs,
    /// the generated IOV route, and the update rate, exactly as audit scenario
    /// 1 requires. Swift encodes `isExternalRoute: false` (non-nil) for a
    /// generated route, unlike CoatyJS which omits the field entirely.
    @Test
    func associateEventEncodesGeneratedRouteFieldsAndIsExternalRoute() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let actorId = try #require(CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let route = "coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333"

        let event = AssociateEvent.with(
            ioContextName: "wire-compat-io-context-1",
            ioSourceId: sourceId,
            ioActorId: actorId,
            associatingRoute: route,
            isExternalRoute: false,
            updateRate: 250
        )

        let json = event.json
        let decoded: AssociateEventData = try PayloadCoder.decode(json)

        #expect(decoded.ioSourceId == sourceId)
        #expect(decoded.ioActorId == actorId)
        #expect(decoded.associatingRoute == route)
        #expect(decoded.updateRate == 250)
        // Swift emits isExternalRoute whenever it is non-nil, including false.
        // This is the asymmetry with CoatyJS, whose AssociateEventData
        // toJsonObject never serializes isExternalRoute (confirmed by capture:
        // T-021 smoke run, coatyjs associate-source role).
        #expect(decoded.isExternalRoute == false)
        #expect(json.contains("\"isExternalRoute\":false"))
    }

    /// A disassociation Associate carries no associating route and no update
    /// rate; both decode to nil. The audit requires that optional-field
    /// *absence* is preserved, not normalized away.
    @Test
    func disassociateEventOmitsRouteAndUpdateRate() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let actorId = try #require(CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444"))

        let event = AssociateEvent.with(
            ioContextName: "wire-compat-io-context-1",
            ioSourceId: sourceId,
            ioActorId: actorId,
            associatingRoute: nil
        )

        let decoded: AssociateEventData = try PayloadCoder.decode(event.json)
        #expect(decoded.associatingRoute == nil)
        #expect(decoded.updateRate == nil)
    }

    /// CoatyJS 2.4.0's `AssociateEventData.toJsonObject` serializes only
    /// `ioSourceId`, `ioActorId`, `associatingRoute`, and `updateRate` — it
    /// never emits `isExternalRoute`, even for an external route. When Axoloty
    /// decodes such a payload, `isExternalRoute` is `nil`.
    ///
    /// `handleAssociate` previously force-unwrapped that field on the
    /// actor-association path, so a CoatyJS Associate received by an Axoloty
    /// actor would trap. The fix defaults the omitted field to `false`
    /// (`event.data.isExternalRoute ?? false`), so an Axoloty actor now
    /// associates on a CoatyJS Associate without crashing. This case locks in
    /// the decode fact the fix depends on: the field is `nil`, not `false`,
    /// when CoatyJS omits it.
    @Test
    func associateEventDecodesCoatyJSPayloadWithoutIsExternalRoute() throws {
        // Exact shape captured from a pinned CoatyJS 2.4.0 associate-source run.
        let coatyJsPayload = """
            {"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333","updateRate":250}
            """

        let decoded: AssociateEventData = try PayloadCoder.decode(coatyJsPayload)

        #expect(decoded.ioSourceId == CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        #expect(decoded.ioActorId == CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        #expect(decoded.associatingRoute == "coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333")
        #expect(decoded.updateRate == 250)
        // The field CoatyJS omits decodes to nil; handleAssociate now defaults
        // this to false rather than force-unwrapping.
        #expect(decoded.isExternalRoute == nil)
        #expect((decoded.isExternalRoute ?? false) == false)
    }

    /// The default generated IOV route is `coaty/3/<namespace>/IOV/<ioSource
    /// objectId>`, using the IoSource ID, not the publishing agent identity
    /// (audit: "the default generated route uses the IoSource ID").
    @Test
    func generatedIoRouteUsesIoSourceObjectId() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
            name: "wire-compat-io-source-1",
            objectId: sourceId
        )
        let communication = CommunicationOptions(
            namespace: "wire-compat-v1",
            mqttClientOptions: MQTTClientOptions(host: "127.0.0.1", port: 1883),
            shouldAutoStart: false
        )
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(communication: communication)
        )
        defer { container.shutdown() }
        let cm = try #require(container.communicationManager)

        let route = cm.createIoRoute(ioSource: source)

        #expect(route == "coaty/3/wire-compat-v1/IOV/33333333-3333-4333-8333-333333333333")
    }

    /// `publishIoValue` publishes the bare payload value, matching pinned
    /// CoatyJS 2.4.0 whose `IoValueEventData.toJsonObject` returns the payload
    /// directly (the scalar `42`, not `{"payload":42}`). Previously Axoloty
    /// sent `event.json`, wrapping the value under a `payload` key; the live
    /// modern→JS capture showed CoatyJS receiving `{"payload":42}`. The fix
    /// encodes the JSON payload directly. This case locks in the bare wire
    /// shape for the JSON path; the raw path uses the byte publish overload.
    @Test
    func ioValueJsonPayloadEncodesAsBareValue() throws {
        // The bare value publishIoValue now puts on the wire for each class,
        // matching CoatyJS (which publishes the payload directly, not wrapped
        // under a "payload" key).
        #expect(try PayloadCoder.encode(AnyCodable(42)) == "42")
        #expect(try PayloadCoder.encode(AnyCodable("héllo 世界 ✓")) == "\"héllo 世界 ✓\"")
        let object: AnyCodable = ["temp": 23.5]
        #expect(try PayloadCoder.encode(object) == "{\"temp\":23.5}")
        let array: AnyCodable = [1, 2, 3]
        #expect(try PayloadCoder.encode(array) == "[1,2,3]")
    }

    // MARK: - Live modern -> JS direction (Axoloty produces, CoatyJS consumes)

    /// Axoloty acts as IO router + IO source: it associates a deterministic
    /// source+actor on a generated IOV route, publishes a JSON IoValue, then
    /// disassociates. A pinned CoatyJS 2.4.0 actor (started by
    /// `IO/Live/run-io-associate.sh`) must decode the Associate, subscribe to
    /// the route, receive the IoValue, and acknowledge at the application
    /// level.
    ///
    /// Disabled outside the live gate so the PR-tier suite stays offline.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_MODERN_TO_JS_LIVE"] == "1"))
    func publishesAssociateAndIoValueForCoatyJS() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"
        let contextName = environment["IO_CONTEXT_NAME"] ?? "wire-compat-io-context-1"

        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let actorId = try #require(CoatyUUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
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

        // Signal readiness only after the subscription to ASC-<context> is
        // acquired, so the CoatyJS actor is started first and the live runner
        // can sequence the producer after this line appears.
        let route = cm.createIoRoute(ioSource: source)
        print("{\"state\":\"ready\",\"scenario\":\"io-associate\",\"route\":\"\(route)\"}")

        // Act as the router: associate source+actor on the generated route.
        try cm.publishAssociate(event: AssociateEvent.with(
            ioContextName: contextName,
            ioSourceId: sourceId,
            ioActorId: actorId,
            associatingRoute: route,
            isExternalRoute: false,
            updateRate: 250
        ))

        // The Associate is delivered back through the broker before the local
        // source's route is registered; settle before publishing the IoValue.
        try await _Concurrency.Task.sleep(for: .milliseconds(1500))

        let event = try IoValueEvent.with(ioSource: source, value: AnyCodable(42), options: [:])
        cm.publishIoValue(event: event)
        print("{\"state\":\"published-iovalue\",\"scenario\":\"io-associate\",\"route\":\"\(route)\"}")

        // publish is fire-and-forget; allow the packet to flush before teardown.
        try await _Concurrency.Task.sleep(for: .milliseconds(1500))

        // Disassociate cleanly.
        try cm.publishAssociate(event: AssociateEvent.with(
            ioContextName: contextName,
            ioSourceId: sourceId,
            ioActorId: actorId,
            associatingRoute: nil
        ))
        try await _Concurrency.Task.sleep(for: .milliseconds(1000))
    }

    // MARK: - Live JS -> modern direction (Axoloty is the actor)

    /// The JS -> modern mirror of scenario 1: pinned CoatyJS 2.4.0 is the IO
    /// router + source and Axoloty is the actor under test. CoatyJS publishes
    /// an Associate that omits `isExternalRoute` (its `toJsonObject` never
    /// serializes it); before the fix, `handleAssociate` force-unwrapped that
    /// field and Axoloty trapped. Now it defaults to false, the actor
    /// associates, and the bare IoValue (`42`) is received.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_JS_TO_MODERN_LIVE"] == "1"))
    func decodesAssociateAndIoValueFromCoatyJS() async throws {
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

        // Printed only after the ASC-<context> subscription is acquired, so the
        // live runner can start the CoatyJS producer once this line appears. The
        // runner allocates a TTY for this process (podman run -t) so `swift
        // test` streams this line to the log promptly instead of block-buffering
        // the child test binary's stdout until exit.
        print("{\"state\":\"ready\",\"scenario\":\"io-associate-js-to-modern\"}")

        // The CoatyJS Associate omits isExternalRoute; the fix defaults it to
        // false instead of trapping, so the actor's IoState flips to associated.
        // (The stream emits an initial hasAssociations=false snapshot; skip it.)
        var state = try await nextSnapshot(&stateIterator, timeout: .seconds(45), "IoState")
        while !state.hasAssociations {
            state = try await nextSnapshot(&stateIterator, timeout: .seconds(45), "IoState")
        }
        #expect(state.hasAssociations == true)

        // The bare IoValue (`42`) CoatyJS publishes on the generated route.
        let value = try await nextSnapshot(&valueIterator, timeout: .seconds(30), "IoValue")
        #expect(String(decoding: value.payload, as: UTF8.self) == "42")

        print("{\"state\":\"ack\",\"scenario\":\"io-associate-js-to-modern\"}")
    }
}

/// Awaits the iterator's next element, giving up after `timeout`.
///
/// `EventStream.Iterator.next()` suspends until an element arrives or the stream
/// finishes, so a bare deadline check cannot bound it — the wait has to race the
/// pull against a timer. This delegates to the shared `nextValue` (which holds
/// the iterator in an actor across the race) and converts its generic timeout /
/// stream-ended errors into the `AxolotyError.runtime` categories these
/// assertions switch on, preserving the `label` in the reason.
private func nextSnapshot<E: Sendable>(
    _ iterator: inout AsyncStream<E>.Iterator,
    timeout: Duration,
    _ label: String
) async throws -> E {
    do {
        return try await nextValue(&iterator, timeout: timeout)
    } catch is CancellationError {
        throw AxolotyError.runtime(code: .streamEnded, reason: "Stream ended while waiting for \(label)")
    } catch {
        throw AxolotyError.runtime(code: .timedOut, reason: "Timed out waiting for \(label)")
    }
}
