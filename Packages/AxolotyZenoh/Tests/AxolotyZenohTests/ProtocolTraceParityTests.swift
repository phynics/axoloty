// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyProtocol
import AxolotyTestBroker
import AxolotyWire
import Foundation
import Testing
@testable import AxolotyMQTT
@testable import AxolotyZenoh
@testable import AxolotyZenohCore
@testable import AxolotyProtocolTraceTestSupport

@Suite("MQTT and Zenoh protocol trace parity")
struct ProtocolTraceParityTests {
    // See ../../CONFORMANCE.md for the transport-limit trace rationale.
    //
    // `negative-payload-limit` measures the JSON fixture against the 2_048-byte
    // payload bound, so the encoding-neutral CBOR leg cannot reproduce its
    // rejection. `malformed-IOV` relies on the `coaty/3` bare-value first-byte
    // sniff: every byte opens a legal CBOR item, so `axoloty/1` accepts the
    // fixture the JSON leg rejects. Both differences are profile-defined.
    private static let tracesExcludedFromCarrierParity: Set<String> = [
        "negative-payload-limit",
        "malformed-IOV",
    ]

    @Test("the shared corpus has identical normalized observations on both carriers")
    func carrierTraceParity() async throws {
        let storedCorpus = try ProtocolTraceCorpus.load()
        let corpus = storedCorpus.filter { !Self.tracesExcludedFromCarrierParity.contains($0.id) }
        #expect(storedCorpus.count == 35)
        #expect(corpus.count == 33)
        #expect(Set(storedCorpus.map(\.id)).subtracting(Set(corpus.map(\.id))) == Self.tracesExcludedFromCarrierParity)
        let broker = TestMQTTBroker(configuration: .init(excludesPublisherFromDelivery: true))
        let port = try broker.start()
        defer { broker.stop() }

        let mqttConfiguration = try MQTTBindingConfiguration(
            host: broker.host,
            port: UInt16(port),
            connectionTimeoutMS: 2_000,
            operationTimeoutMS: 2_000
        )
        let zenohConfiguration = try ZenohBindingConfiguration()
        // The MQTT leg keeps the sealed `coaty/3` JSON contract and asserts the
        // corpus expected observation. The Zenoh leg composes the `axoloty/1`
        // CBOR profile, so it re-encodes each JSON fixture and skips the
        // expected-assertion until an explicit CBOR observation exists.
        let mqttAdapter = RuntimeTraceReplayAdapter {
            MQTTTraceCarrier(binding: try MQTTBinding(configuration: mqttConfiguration), broker: broker)
        }
        let zenohAdapter = RuntimeTraceReplayAdapter(
            profile: .axoloty1CBOR,
            payloadOverride: { trace in
                TracePayloadCBOR.overrides(for: trace, profileRoutePrefix: "axoloty/1")
            },
            assertExpected: false
        ) {
            let session = RecordingZenohSession()
            let clock = TraceFrameClock()
            let binding = ZenohBinding(configuration: zenohConfiguration, session: session, clock: { clock.value })
            return ZenohTraceCarrier(binding: binding, session: session, clock: clock)
        }

        let mqttRuns = try await replay(corpus, using: mqttAdapter)
        let zenohRuns = try await replay(corpus, using: zenohAdapter)

        #expect(mqttRuns.map(normalizeRun) == zenohRuns.map(normalizeRun))
        #expect(mqttRuns.count == corpus.count)
        #expect(Set(mqttRuns.map(\.traceID)) == Set(corpus.map(\.id)))
        expectEveryFamilyCovered(by: mqttRuns)
        expectEveryFamilyCovered(by: zenohRuns)
        #expect(mqttRuns.first { $0.traceID == "multi-step-duplicate" }?.observations.count == 2)
        #expect(mqttRuns.first { $0.traceID == "negative-deadline" }?.observations.first?.rejection?.code == .deadlineExpired)
        #expect(mqttRuns.first { $0.traceID == "negative-duplicate" }?.observations.first?.rejection?.code == .duplicate)
    }

    @Test("route classification follows each carrier's bound profile")
    func routeClassificationParity() async throws {
        let broker = TestMQTTBroker()
        let port = try broker.start()
        defer { broker.stop() }

        let mqtt = try MQTTBinding(configuration: MQTTBindingConfiguration(
            host: broker.host,
            port: UInt16(port),
            connectionTimeoutMS: 2_000,
            operationTimeoutMS: 2_000
        ))
        let zenohSession = RecordingZenohSession()
        let zenoh = try ZenohBinding(configuration: ZenohBindingConfiguration(), session: zenohSession)
        try await mqtt.start { _ in }
        try await zenoh.start { _ in }
        try await mqtt.activateProfileInterest(namespace: "node")
        try await zenoh.activateProfileInterest(namespace: "node")
        #expect(mqtt.wireProfile == .coaty3JSON)
        #expect(zenoh.wireProfile == .axoloty1CBOR)

        // The Zenoh binding installs only `axoloty/1` profile shapes.
        let profileSubscriptions = zenohSession.withOperations { operations in
            operations.compactMap { operation -> String? in
                guard case let .subscribe(route, _) = operation else { return nil }
                return String(decoding: route, as: UTF8.self)
            }
        }
        #expect(profileSubscriptions == ["axoloty/1/node/*/*", "axoloty/1/node/*/*/*"])

        // The MQTT binding is bound to `coaty/3` JSON.
        let mqttCases: [(String, [UInt8], ProtocolRouteClassification)] = [
            ("active IOV", Array("coaty/3/node/IOV/00000000-0000-4000-8000-000000000001".utf8), .coaty),
            ("other profile family", Array("coaty/3/node/ADV/00000000-0000-4000-8000-000000000001".utf8), .unrelated),
            ("inactive namespace", Array("coaty/3/other/IOV/00000000-0000-4000-8000-000000000001".utf8), .unrelated),
            ("foreign profile", Array("axoloty/1/node/IOV/00000000-0000-4000-8000-000000000001".utf8), .external),
            ("external route", Array("legacy/source/value".utf8), .external),
            ("empty segment", Array("bad//route".utf8), .unrelated),
            ("plus wildcard", Array("bad/+/route".utf8), .unrelated),
            ("star wildcard", Array("bad/*/route".utf8), .external),
            ("non-UTF-8 key", [0xFF], .external),
        ]
        // The Zenoh binding is bound to `axoloty/1` CBOR, so `coaty/3` is a
        // foreign profile and the MQTT star-wildcard quirk does not apply.
        let zenohCases: [(String, [UInt8], ProtocolRouteClassification)] = [
            ("active IOV", Array("axoloty/1/node/IOV/00000000-0000-4000-8000-000000000001".utf8), .coaty),
            ("other profile family", Array("axoloty/1/node/ADV/00000000-0000-4000-8000-000000000001".utf8), .unrelated),
            ("inactive namespace", Array("axoloty/1/other/IOV/00000000-0000-4000-8000-000000000001".utf8), .unrelated),
            ("foreign profile", Array("coaty/3/node/IOV/00000000-0000-4000-8000-000000000001".utf8), .external),
            ("external route", Array("legacy/source/value".utf8), .external),
            ("empty segment", Array("bad//route".utf8), .unrelated),
            ("plus wildcard", Array("bad/+/route".utf8), .unrelated),
            ("star wildcard", Array("bad/*/route".utf8), .unrelated),
            ("non-UTF-8 key", [0xFF], .external),
        ]

        for (name, bytes, expected) in mqttCases {
            #expect(classify(bytes, using: mqtt) == expected, "MQTT classification for \(name)")
        }
        for (name, bytes, expected) in zenohCases {
            #expect(classify(bytes, using: zenoh) == expected, "Zenoh classification for \(name)")
        }
        let invalidUTF8Inbound = ZenohBindingSupport.inboundFrame(
            routeBytes: [0xFF],
            payload: [],
            nowMS: 0,
            routeState: ZenohInboundRouteState(
                activeNamespace: "node",
                externalRoutes: [[0xFF]],
                maximumProfileKeyLength: ZenohFrameStorage.keyCapacity
            )
        )
        #expect(invalidUTF8Inbound == nil)
        await mqtt.stop()
        await zenoh.stop()
    }

    private func replay(
        _ corpus: [ProtocolTrace],
        using adapter: any TraceReplayAdapter
    ) async throws -> [TraceRun] {
        var runs: [TraceRun] = []
        for trace in corpus {
            runs.append(try await adapter.replay(trace))
        }
        return runs
    }

    /// Projects one carrier run onto the encoding-neutral trace contract.
    ///
    /// The route prefix and the action payload bytes are the only fields that
    /// may differ between the `coaty/3` JSON and `axoloty/1` CBOR legs. The
    /// trace contract's normalized observation compares operations, state, and
    /// structured rejections, so canonicalize the prefix and drop payload
    /// bytes before comparing.
    private func normalizeRun(_ run: TraceRun) -> TraceRun {
        TraceRun(
            traceID: run.traceID,
            observations: run.observations.map { observation in
                TraceObservation(
                    actions: observation.actions.map { action in
                        TraceAction(
                            kind: action.kind,
                            family: action.family,
                            correlationID: action.correlationID,
                            route: action.route.map(canonicalRoute),
                            payload: nil
                        )
                    },
                    rejection: observation.rejection,
                    nextState: observation.nextState
                )
            }
        )
    }

    private func canonicalRoute(_ route: String) -> String {
        guard route.hasPrefix("axoloty/1/") else { return route }
        return "coaty/3/" + route.dropFirst("axoloty/1/".count)
    }

    private func expectEveryFamilyCovered(by runs: [TraceRun]) {
        let traceIDs = Set(runs.map(\.traceID))
        for family in TraceEventFamily.allCases {
            #expect(traceIDs.contains("positive-\(family.rawValue)"))
            // `malformed-IOV` is profile-defined: `axoloty/1` has no bare-value
            // first-byte sniff, so it is not part of cross-profile parity.
            if family != .ioValue {
                #expect(traceIDs.contains("malformed-\(family.rawValue)"))
            }
        }
    }

    private func classify(_ bytes: [UInt8], using transport: any AxolotyRuntimeTransport) -> ProtocolRouteClassification {
        bytes.withUnsafeBufferPointer { buffer in
            let view = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            return transport.classifyRoute(view)
        }
    }
}
