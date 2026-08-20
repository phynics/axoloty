// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Suite("G2 protocol trace corpus")
struct ProtocolTraceTests {
    @Test("the corpus covers every Coaty Core family with positive and malformed traces")
    func corpusCoverage() throws {
        let corpus = try ProtocolTraceCorpus.load()
        let positiveFamilies = Set(corpus.filter { $0.id.hasPrefix("positive-") }.compactMap { $0.steps.first?.input.family })
        let malformedFamilies = Set(corpus.filter { $0.id.hasPrefix("malformed-") }.compactMap { $0.steps.first?.input.family })

        #expect(TraceEventFamily.allCases.count == 13)
        #expect(positiveFamilies == ProtocolTraceCorpus.eventFamilies)
        #expect(malformedFamilies == ProtocolTraceCorpus.eventFamilies)
        #expect(corpus.count == 33)
        #expect(corpus.allSatisfy { $0.steps.first?.input.fixtureID.hasPrefix("Tests/ProtocolTrace/Fixtures/family-seeds.json#") == true })
        #expect(corpus.filter { $0.id.hasPrefix("malformed-") }.allSatisfy { $0.steps.first?.input.malformed == true })
        #expect(corpus.contains { trace in
            trace.id == "positive-external-route" && trace.steps.first?.input.isExternalRoute == true
        })
    }

    @Test("canonical serialization is stable and schema-shaped")
    func canonicalSerialization() throws {
        let corpus = try ProtocolTraceCorpus.load()
        let first = try ProtocolTraceCanonicalEncoding.data(for: corpus)
        let second = try ProtocolTraceCanonicalEncoding.data(for: corpus)
        #expect(first == second)

        let document = try #require(JSONSerialization.jsonObject(with: first) as? [[String: Any]])
        #expect(document.count == corpus.count)
        #expect(document.allSatisfy { ($0["schemaVersion"] as? Int) == ProtocolTrace.schemaVersion })
        #expect(document.allSatisfy { $0["initialState"] is [String: Any] })
        #expect(document.allSatisfy { $0["steps"] is [[String: Any]] })
    }

    @Test("host and static replay adapters produce identical observations")
    func hostAndStaticReplayEquality() throws {
        let corpus = try ProtocolTraceCorpus.load()
        let host = try replayAll(adapter: HostTraceReplayAdapter(), corpus: corpus)
        let `static` = try replayAll(adapter: StaticTraceReplayAdapter(), corpus: corpus)
        #expect(host == `static`)
        #expect(host.count == corpus.count)
        #expect(host.allSatisfy { $0.observations.count == 1 })
    }

    @Test("bounded failures are explicit and state preserving")
    func boundedFailures() throws {
        let corpus = try ProtocolTraceCorpus.load()
        let runs = try replayAll(adapter: HostTraceReplayAdapter(), corpus: corpus)
        let byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.traceID, $0) })
        let expected: [String: TraceRejectionCode] = [
            "negative-saturation": .saturated,
            "negative-duplicate": .duplicate,
            "negative-stale-correlation": .correlationMismatch,
            "negative-unsupported": .unsupported,
            "negative-deadline": .deadlineExpired,
            "negative-payload-limit": .payloadTooLarge,
        ]

        for (traceID, code) in expected {
            let run = try #require(byID[traceID])
            let observation = try #require(run.observations.first)
            #expect(observation.rejection?.code == code)
            #expect(observation.actions.isEmpty)
            #expect(observation.nextState == corpus.first { $0.id == traceID }?.initialState)
        }
    }

    @Test("replay rejects a broken state chain")
    func brokenStateChainIsRejected() throws {
        let original = try #require(try ProtocolTraceCorpus.load().first { $0.id == "positive-ADV" })
        let brokenStep = TraceStep(
            sequence: original.steps[0].sequence,
            timeMilliseconds: original.steps[0].timeMilliseconds,
            priorState: TraceState(activeObjectIDs: ["unexpected"]),
            capabilities: original.steps[0].capabilities,
            limits: original.steps[0].limits,
            input: original.steps[0].input,
            localOperation: original.steps[0].localOperation,
            expected: original.steps[0].expected
        )
        let broken = ProtocolTrace(
            id: original.id,
            description: original.description,
            initialState: original.initialState,
            steps: [brokenStep]
        )

        #expect(throws: TraceReplayError.stateMismatch(traceID: original.id, sequence: 1)) {
            _ = try HostTraceReplayAdapter().replay(broken)
        }
    }

    @Test("the checked-in JSON schema names the complete trace contract")
    func schemaContract() throws {
        let schemaURL = try #require(Bundle.module.url(forResource: "trace.schema", withExtension: "json"))
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
        #expect(schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
        #expect(schema["title"] as? String == "Axoloty G2 Protocol Trace")
        #expect((schema["required"] as? [String]) == ["schemaVersion", "id", "description", "initialState", "steps"])
    }

    private func replayAll(adapter: any TraceReplayAdapter, corpus: [ProtocolTrace]) throws -> [TraceRun] {
        try corpus.map { try adapter.replay($0) }
    }
}
