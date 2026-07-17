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
    /// This is the root cause of the defect the audit flags at
    /// `CommunicationManager.swift:557`: `handleAssociate` force-unwraps
    /// `event.data.isExternalRoute!` on the actor-association path. A CoatyJS
    /// Associate received by an Axoloty actor would therefore crash rather than
    /// default the field. This case records the decode fact; the crash is
    /// documented in the decisions doc and exercised by the live JS -> modern
    /// runner.
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
        // The field CoatyJS omits decodes to nil — the value that the
        // force-unwrap in handleAssociate would trap on.
        #expect(decoded.isExternalRoute == nil)
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

    /// Axoloty's JSON IoValue event wraps the value under a `payload` key
    /// (`IoValueEventData.encode`), whereas pinned CoatyJS 2.4.0 publishes the
    /// raw JSON value itself (its `IoValueEventData.toJsonObject` returns the
    /// payload directly, confirmed by capture: the scalar IoValue was the
    /// two-byte string `42`, not `{"payload":42}`).
    ///
    /// Note: IoValues are not round-tripped through `PayloadCoder` on the
    /// receive path — the transport delivers an `IoValueEventSnapshot` carrying
    /// the raw bytes (`didReceiveIoValue`), so a consumer interprets the bytes
    /// directly. This case records only the wire shape Axoloty emits; the
    /// cross-implementation decode outcome is captured by the live runners.
    @Test
    func ioValueEventWrapsJsonValueUnderPayloadKey() throws {
        let sourceId = try #require(CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let source = IoSource(
            valueType: "com.coaty.test.WireIoValue",
            name: "wire-compat-io-source-1",
            objectId: sourceId
        )
        let event = try IoValueEvent.with(
            ioSource: source,
            value: AnyCodable(42),
            options: [:]
        )

        // Axoloty wraps the value under "payload"; a CoatyJS peer emitting the
        // bare value `42` would not match this shape.
        #expect(event.json == "{\"payload\":42}")
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
}
