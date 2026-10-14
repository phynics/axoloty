// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import Axoloty
import AxolotyProtocol
import AxolotyWire
@testable import AxolotyProtocolTraceTestSupport

/// Replays the same logical protocol traces through the host/`coaty/3`/JSON
/// leg and the static/`axoloty/1`/CBOR leg, then compares operations, state,
/// and structured rejections.
///
/// The trace corpus stores `coaty/3` JSON fixture text in its sealed schema.
/// This suite pairs each step with the frozen `axoloty/1` CBOR bytes from the
/// T5 golden corpus that encode the same logical payload. Both replays use the
/// same object, correlation, and route decisions; only the bound route prefix
/// (`coaty/3` vs `axoloty/1`) and the raw payload bytes differ. The suite drops
/// action payload bytes before comparing, so any difference in operations,
/// normalized state, or rejection codes fails the comparison.
///
/// `ioState` is intentionally absent: it is not one of the thirteen
/// ``TraceEventFamily`` wire families.
@Suite("Wire CBOR trace parity")
struct WireCBORTraceParityTests {
    // MARK: - Fixture loading

    private static let goldenDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../WireCompatibility/Golden", isDirectory: true)
        .standardizedFileURL

    private struct GoldenManifest: Decodable {
        struct Case: Decodable {
            let id: String
            let family: String
            let json: String
            let cbor: String
        }

        let cases: [Case]
    }

    private struct GoldenCase {
        let id: String
        let family: String
        let json: String
        let cbor: [UInt8]
    }

    private static func loadManifest() throws -> GoldenManifest {
        let url = goldenDirectory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GoldenManifest.self, from: data)
    }

    private static func loadGolden(_ manifest: GoldenManifest, id: String) throws -> GoldenCase {
        guard let entry = manifest.cases.first(where: { $0.id == id }) else {
            throw ParityFixtureError.missingCase(id)
        }
        let json = try String(
            contentsOf: goldenDirectory.appendingPathComponent(entry.json),
            encoding: .utf8
        )
        let cbor = [UInt8](try Data(contentsOf: goldenDirectory.appendingPathComponent(entry.cbor)))
        return GoldenCase(id: entry.id, family: entry.family, json: json, cbor: cbor)
    }

    private enum ParityFixtureError: Error, CustomStringConvertible {
        case missingCase(String)

        var description: String {
            switch self {
            case .missingCase(let id): "missing golden case \(id)"
            }
        }
    }

    // MARK: - Trace construction

    /// The canonical fallback identity text for the golden `55555555` object
    /// UUID. The advertised object id is the payload's `objectId`, not the
    /// routed source, so the ADV step activates this id.
    private static let advertisedObjectID = "55555555-0000-4000-8000-000000000001"

    private static let afterAdvertise = TraceState(
        activeObjectIDs: [advertisedObjectID],
        generation: 1
    )

    private static let afterRequest = TraceState(
        pendingCorrelationIDs: ["correlation-001"],
        generation: 1
    )

    private static func step(
        sequence: Int,
        family: TraceEventFamily,
        direction: TraceDirection,
        payload: String,
        objectID: String? = nil,
        correlationID: String? = nil,
        priorState: TraceState = TraceState()
    ) -> TraceStep {
        let input = TraceInput(
            family: family,
            direction: direction,
            fixtureID: "wire-cbor-trace/\(family.rawValue)/\(sequence)",
            fixturePayload: payload,
            objectID: objectID,
            correlationID: correlationID
        )
        return TraceStep(
            sequence: sequence,
            timeMilliseconds: UInt64(sequence) * 10,
            priorState: priorState,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: input,
            localOperation: direction == .inbound ? .processInbound : .publishOutbound,
            expected: TraceObservation(actions: [], rejection: nil, nextState: TraceState())
        )
    }

    /// One replay fixture: a JSON-authored trace plus the CBOR bytes that
    /// replace each step's payload for the static leg.
    ///
    /// `rejections` is the corpus oracle. Every step named there must reject
    /// with the given code and emit no action; every other step must accept,
    /// emit no rejection, and emit at least one action of the step's family.
    /// A silent no-op therefore fails the comparison instead of passing as an
    /// empty-versus-empty match.
    private struct ParityCase {
        let id: String
        let families: [TraceEventFamily]
        let trace: ProtocolTrace
        let cborBySequence: [Int: [UInt8]]
        var rejections: [Int: TraceRejectionCode] = [:]
    }

    private static func buildCases() throws -> [ParityCase] {
        let manifest = try loadManifest()
        var cases: [ParityCase] = []

        // Advertise then deadvertise: one object enters the table and leaves.
        let advertise = try loadGolden(manifest, id: "advertise-object-uuid")
        let deadvertise = try loadGolden(manifest, id: "deadvertise-multiple")
        cases.append(ParityCase(
            id: "adv-dad",
            families: [.advertise, .deadvertise],
            trace: ProtocolTrace(
                id: "wire-cbor-adv-dad",
                description: "Advertise then deadvertise the same object",
                initialState: TraceState(),
                steps: [
                    step(
                        sequence: 1,
                        family: .advertise,
                        direction: .inbound,
                        payload: advertise.json,
                        objectID: "object-001"
                    ),
                    step(
                        sequence: 2,
                        family: .deadvertise,
                        direction: .inbound,
                        payload: deadvertise.json,
                        objectID: "object-001",
                        priorState: afterAdvertise
                    )
                ]
            ),
            cborBySequence: [1: advertise.cbor, 2: deadvertise.cbor]
        ))

        // One-step inbound families with no pending request.
        let channel = try loadGolden(manifest, id: "channel-full")
        cases.append(ParityCase(
            id: "chn",
            families: [.channel],
            trace: ProtocolTrace(
                id: "wire-cbor-chn",
                description: "Channel update",
                initialState: TraceState(),
                steps: [
                    step(sequence: 1, family: .channel, direction: .inbound, payload: channel.json)
                ]
            ),
            cborBySequence: [1: channel.cbor]
        ))

        // The full associate fixture carries `associatingRoute` and
        // `isExternalRoute: true`. The replay binds it to the profile route,
        // which the host transport and the static classifier both classify as
        // non-external, so both legs must reject the external flag as a
        // structured `externalRouteMismatch`. This exercises the associate
        // family without a silent no-op (the minimal fixture omits the route
        // and is ignored by design).
        let associate = try loadGolden(manifest, id: "associate-full")
        cases.append(ParityCase(
            id: "asc",
            families: [.associate],
            trace: ProtocolTrace(
                id: "wire-cbor-asc",
                description: "Associate an IO endpoint",
                initialState: TraceState(),
                steps: [
                    step(
                        sequence: 1,
                        family: .associate,
                        direction: .inbound,
                        payload: associate.json,
                        objectID: "object-001"
                    )
                ]
            ),
            cborBySequence: [1: associate.cbor],
            rejections: [1: .externalRouteMismatch]
        ))

        let ioValue = try loadGolden(manifest, id: "iovalue-array")
        cases.append(ParityCase(
            id: "iov",
            families: [.ioValue],
            trace: ProtocolTrace(
                id: "wire-cbor-iov",
                description: "IO value array payload",
                initialState: TraceState(),
                steps: [
                    step(sequence: 1, family: .ioValue, direction: .inbound, payload: ioValue.json)
                ]
            ),
            cborBySequence: [1: ioValue.cbor]
        ))

        // An orphan response has no pending request. Both profiles must reject
        // it with a structured correlation mismatch and leave state unchanged.
        let orphanResolve = try loadGolden(manifest, id: "resolve-minimal")
        cases.append(ParityCase(
            id: "rsv-orphan",
            families: [.resolve],
            trace: ProtocolTrace(
                id: "wire-cbor-rsv-orphan",
                description: "Resolve without a pending correlation",
                initialState: TraceState(),
                steps: [
                    step(
                        sequence: 1,
                        family: .resolve,
                        direction: .inbound,
                        payload: orphanResolve.json,
                        correlationID: "correlation-001"
                    )
                ]
            ),
            cborBySequence: [1: orphanResolve.cbor],
            rejections: [1: .correlationMismatch]
        ))

        // Request and response families are separate one-step cases. A
        // pending request established by an earlier trace step is not visible
        // to the host runtime's local request continuation at the moment the
        // next step is injected, so a two-step request/response trace would
        // compare a host no-op against a static deliver. The maintained corpus
        // establishes pending state once through the production Interface
        // (see ``ProtocolTraceRuntimeReplay``) and then replays the response;
        // these cases mirror that shape by seeding `afterRequest` as the
        // initial state of the response step.
        let discover = try loadGolden(manifest, id: "discover-full")
        let resolve = try loadGolden(manifest, id: "resolve-minimal")
        cases.append(familyCase(
            id: "dsc",
            family: .discover,
            direction: .outbound,
            golden: discover,
            correlationID: "correlation-001"
        ))
        cases.append(familyCase(
            id: "rsv",
            family: .resolve,
            direction: .inbound,
            golden: resolve,
            correlationID: "correlation-001",
            state: afterRequest
        ))

        let query = try loadGolden(manifest, id: "query-full")
        let retrieve = try loadGolden(manifest, id: "retrieve-minimal")
        cases.append(familyCase(
            id: "qry",
            family: .query,
            direction: .outbound,
            golden: query,
            correlationID: "correlation-001"
        ))
        cases.append(familyCase(
            id: "rtv",
            family: .retrieve,
            direction: .inbound,
            golden: retrieve,
            correlationID: "correlation-001",
            state: afterRequest
        ))

        let update = try loadGolden(manifest, id: "update-full")
        let complete = try loadGolden(manifest, id: "complete-full")
        cases.append(familyCase(
            id: "upd",
            family: .update,
            direction: .outbound,
            golden: update,
            correlationID: "correlation-001"
        ))
        cases.append(familyCase(
            id: "cpl",
            family: .complete,
            direction: .inbound,
            golden: complete,
            correlationID: "correlation-001",
            state: afterRequest
        ))

        let call = try loadGolden(manifest, id: "call-full")
        let returned = try loadGolden(manifest, id: "return-full")
        cases.append(familyCase(
            id: "cll",
            family: .call,
            direction: .outbound,
            golden: call,
            correlationID: "correlation-001"
        ))
        cases.append(familyCase(
            id: "rtn",
            family: .return,
            direction: .inbound,
            golden: returned,
            correlationID: "correlation-001",
            state: afterRequest
        ))

        return cases
    }

    /// Builds a one-step parity case. `state` is both the trace's initial
    /// state and the step's prior state, so the replay seeds it through the
    /// production Interface exactly once.
    private static func familyCase(
        id: String,
        family: TraceEventFamily,
        direction: TraceDirection,
        golden: GoldenCase,
        objectID: String? = nil,
        correlationID: String? = nil,
        state: TraceState = TraceState()
    ) -> ParityCase {
        ParityCase(
            id: id,
            families: [family],
            trace: ProtocolTrace(
                id: "wire-cbor-\(id)",
                description: "\(family.rawValue) \(direction == .inbound ? "inbound" : "outbound")",
                initialState: state,
                steps: [
                    step(
                        sequence: 1,
                        family: family,
                        direction: direction,
                        payload: golden.json,
                        objectID: objectID,
                        correlationID: correlationID,
                        priorState: state
                    )
                ]
            ),
            cborBySequence: [1: golden.cbor]
        )
    }

    // MARK: - Comparison

    /// Drops action payload bytes so only the profile-independent operation,
    /// correlation, route class, normalized state, and rejection remain.
    private static func normalize(_ run: TraceRun) -> TraceRun {
        TraceRun(traceID: run.traceID, observations: run.observations.map { observation in
            TraceObservation(
                actions: observation.actions.map {
                    TraceAction(
                        kind: $0.kind,
                        family: $0.family,
                        correlationID: $0.correlationID,
                        route: $0.route,
                        payload: nil
                    )
                },
                rejection: observation.rejection,
                nextState: observation.nextState
            )
        })
    }

    private static func replayHostJSON(_ trace: ProtocolTrace) async throws -> TraceRun {
        // The corpus `expected` observations in these ad-hoc traces carry no
        // payload bytes, and the two legs legitimately differ in payload
        // bytes, so the engine's exact `assertExpected` stays off. The
        // profile-independent oracle below is the assertion that matters here.
        try await HostTraceReplayAdapter(assertExpected: false).replay(trace)
    }

    /// Applies the corpus oracle to one normalized replay run.
    private static func assertOracle(_ run: TraceRun, item: ParityCase, leg: String) {
        for (index, step) in item.trace.steps.enumerated() {
            let observation = run.observations[index]
            if let code = item.rejections[step.sequence] {
                #expect(observation.rejection?.code == code, "case \(item.id) \(leg) step \(step.sequence) rejection")
                #expect(observation.actions.isEmpty, "case \(item.id) \(leg) step \(step.sequence) rejected but emitted actions")
                continue
            }
            let kind = step.localOperation == .publishOutbound ? "publish" : "deliver"
            #expect(observation.rejection == nil, "case \(item.id) \(leg) step \(step.sequence) unexpectedly rejected")
            #expect(!observation.actions.isEmpty, "case \(item.id) \(leg) step \(step.sequence) produced no action and no rejection")
            #expect(
                observation.actions.allSatisfy { $0.kind == kind && $0.family == step.input.family },
                "case \(item.id) \(leg) step \(step.sequence) action shape"
            )
        }
    }

    private static func replayStaticCBOR(_ item: ParityCase) async throws -> TraceRun {
        try await ProfileStaticTraceReplayAdapter(
            profile: .axoloty1CBOR,
            payloadOverride: item.cborBySequence,
            assertExpected: false
        ).replay(item.trace)
    }

    // MARK: - Tests

    @Test("Every wire family has a paired JSON/CBOR trace")
    func coversEveryWireFamily() throws {
        let cases = try Self.buildCases()
        let families = Set(cases.flatMap(\.families))
        #expect(families == Set(TraceEventFamily.allCases))
        #expect(cases.count == 13)
        #expect(TraceEventFamily.allCases.count == 13)
    }

    @Test("JSON and CBOR replays agree on operations, state, and rejections")
    func replaysAgreeAcrossProfiles() async throws {
        var accepted = 0
        var rejected = 0
        for item in try Self.buildCases() {
            let jsonRun = try await Self.replayHostJSON(item.trace)
            let cborRun = try await Self.replayStaticCBOR(item)
            #expect(Self.normalize(jsonRun) == Self.normalize(cborRun), "case \(item.id)")
            #expect(jsonRun.observations.count == item.trace.steps.count, "case \(item.id)")
            Self.assertOracle(jsonRun, item: item, leg: "JSON")
            Self.assertOracle(cborRun, item: item, leg: "CBOR")
            for observation in cborRun.observations {
                if observation.rejection == nil { accepted += 1 } else { rejected += 1 }
            }
        }
        #expect(accepted > 0)
        #expect(rejected > 0)
    }

    @Test("Static CBOR leg consumes CBOR bytes, not JSON text")
    func staticLegConsumesCBORBytes() async throws {
        for item in try Self.buildCases() {
            let cborRun = try await Self.replayStaticCBOR(item)
            for (index, step) in item.trace.steps.enumerated() {
                guard let bytes = item.cborBySequence[step.sequence] else { continue }
                #expect(bytes != Array(step.input.fixturePayload.utf8), "case \(item.id) step \(step.sequence)")
                for action in cborRun.observations[index].actions {
                    #expect(action.payload == bytes, "case \(item.id) step \(step.sequence)")
                }
            }
        }
    }

    @Test("Duplicate advertise is rejected identically")
    func rejectionShapeAgrees() async throws {
        let manifest = try Self.loadManifest()
        let advertise = try Self.loadGolden(manifest, id: "advertise-object-uuid")
        let trace = ProtocolTrace(
            id: "wire-cbor-duplicate",
            description: "Two advertises for the same object",
            initialState: TraceState(),
            steps: [
                Self.step(
                    sequence: 1,
                    family: .advertise,
                    direction: .inbound,
                    payload: advertise.json,
                    objectID: "object-001"
                ),
                Self.step(
                    sequence: 2,
                    family: .advertise,
                    direction: .inbound,
                    payload: advertise.json,
                    objectID: "object-001",
                    priorState: Self.afterAdvertise
                )
            ]
        )
        let item = ParityCase(
            id: "sat",
            families: [.advertise],
            trace: trace,
            cborBySequence: [1: advertise.cbor, 2: advertise.cbor],
            rejections: [2: .duplicate]
        )
        let jsonRun = try await Self.replayHostJSON(item.trace)
        let cborRun = try await Self.replayStaticCBOR(item)
        #expect(Self.normalize(jsonRun) == Self.normalize(cborRun))
        Self.assertOracle(jsonRun, item: item, leg: "JSON")
        Self.assertOracle(cborRun, item: item, leg: "CBOR")
        // The second advertise is the duplicate; both profiles must reject it
        // with the same structured code and preserve the table.
        #expect(cborRun.observations[1].rejection != nil)
        #expect(cborRun.observations[1].nextState == Self.afterAdvertise)
    }
}
