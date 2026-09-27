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
    @Test("the shared corpus has identical normalized observations on both carriers")
    func carrierTraceParity() async throws {
        let storedCorpus = try ProtocolTraceCorpus.load()
        let corpus = storedCorpus.filter { $0.id != "negative-payload-limit" }
        #expect(storedCorpus.count == 35)
        #expect(corpus.count == 34)
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
        let mqttAdapter = RuntimeTraceReplayAdapter {
            MQTTTraceCarrier(binding: try MQTTBinding(configuration: mqttConfiguration), broker: broker)
        }
        let zenohAdapter = RuntimeTraceReplayAdapter {
            let session = RecordingZenohSession()
            let clock = TraceFrameClock()
            let binding = ZenohBinding(configuration: zenohConfiguration, session: session, clock: { clock.value })
            return ZenohTraceCarrier(binding: binding, session: session, clock: clock)
        }

        let mqttRuns = try await replay(corpus, using: mqttAdapter)
        let zenohRuns = try await replay(corpus, using: zenohAdapter)

        #expect(mqttRuns == zenohRuns)
        #expect(mqttRuns.count == corpus.count)
        #expect(Set(mqttRuns.map(\.traceID)) == Set(corpus.map(\.id)))
        #expect(mqttRuns.first { $0.traceID == "multi-step-duplicate" }?.observations.count == 2)
        #expect(mqttRuns.first { $0.traceID == "negative-deadline" }?.observations.first?.rejection?.code == .deadlineExpired)
        #expect(mqttRuns.first { $0.traceID == "negative-duplicate" }?.observations.first?.rejection?.code == .duplicate)
    }

    @Test("route classification agrees except for the documented MQTT star row")
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
        let zenoh = try ZenohBinding(configuration: ZenohBindingConfiguration(), session: RecordingZenohSession())
        try await mqtt.start { _ in }
        try await zenoh.start { _ in }
        try await mqtt.activateProfileInterest(namespace: "node")
        try await zenoh.activateProfileInterest(namespace: "node")
        let cases: [(String, [UInt8], ProtocolRouteClassification, ProtocolRouteClassification)] = [
            ("active IOV", Array("coaty/3/node/IOV/00000000-0000-4000-8000-000000000001".utf8), .coaty, .coaty),
            ("other profile family", Array("coaty/3/node/ADV/00000000-0000-4000-8000-000000000001".utf8), .unrelated, .unrelated),
            ("inactive namespace", Array("coaty/3/other/IOV/00000000-0000-4000-8000-000000000001".utf8), .unrelated, .unrelated),
            ("external route", Array("legacy/source/value".utf8), .external, .external),
            ("empty segment", Array("bad//route".utf8), .unrelated, .unrelated),
            ("plus wildcard", Array("bad/+/route".utf8), .unrelated, .unrelated),
            ("star wildcard", Array("bad/*/route".utf8), .external, .unrelated),
            ("non-UTF-8 key", [0xFF], .external, .external),
        ]

        for (name, bytes, mqttExpected, zenohExpected) in cases {
            let mqttActual = classify(bytes, using: mqtt)
            let zenohActual = classify(bytes, using: zenoh)
            #expect(mqttActual == mqttExpected, "MQTT classification for \(name)")
            #expect(zenohActual == zenohExpected, "Zenoh classification for \(name)")
            if name != "star wildcard" {
                #expect(mqttActual == zenohActual, "cross-carrier classification for \(name)")
            }
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

    private func classify(_ bytes: [UInt8], using transport: any AxolotyRuntimeTransport) -> ProtocolRouteClassification {
        bytes.withUnsafeBufferPointer { buffer in
            let view = ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            return transport.classifyRoute(view)
        }
    }
}
