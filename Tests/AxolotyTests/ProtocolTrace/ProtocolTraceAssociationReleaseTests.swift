// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import AxolotyProtocolTraceTestSupport

/// A Deadvertise that removes an association endpoint must free the slot on
/// both runtime profiles. This inline trace proves the host runtime and the
/// fixed-storage runtime observe the same release action and the same empty
/// association set, without adding a corpus entry for an inline scenario.
@Suite("G6 association release trace")
struct ProtocolTraceAssociationReleaseTests {
    @Test("host and static replay report the same association release")
    func hostAndStaticAgreeOnAssociationRelease() async throws {
        let peer = "peer-source"
        let actor = "local-actor"
        let peerIdentity = Self.identityText(peer)
        let actorIdentity = Self.identityText(actor)
        let initialState = TraceState(activeObjectIDs: [peer])

        let associateInput = TraceInput(
            family: .associate,
            direction: .inbound,
            fixtureID: "inline-association-release#1",
            fixturePayload: """
            {"ioSourceId":"\(peerIdentity)","ioActorId":"\(actorIdentity)","associatingRoute":"coaty/io-release"}
            """,
            objectID: peer,
            routeClassification: .coaty
        )
        let associateStep = TraceStep(
            sequence: 1,
            timeMilliseconds: 1,
            priorState: initialState,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: associateInput,
            localOperation: .processInbound,
            expected: TraceObservation(actions: [], rejection: nil, nextState: initialState)
        )

        // The trace schema still requires a prior-state chain, so learn the
        // post-Associate state from a reference replay before building the
        // Deadvertise step.
        let referenceTrace = ProtocolTrace(
            id: "inline-association-release",
            description: "inline association release",
            initialState: initialState,
            steps: [associateStep]
        )
        let reference = try await HostTraceReplayAdapter(assertExpected: false).replay(referenceTrace)
        let afterAssociate = try #require(reference.observations.first).nextState
        #expect(afterAssociate.associationIDs == [peer])

        let deadvertiseInput = TraceInput(
            family: .deadvertise,
            direction: .inbound,
            fixtureID: "inline-association-release#2",
            fixturePayload: "{\"objectIds\":[\"\(peerIdentity)\"]}",
            objectID: peer,
            routeClassification: .coaty
        )
        let deadvertiseStep = TraceStep(
            sequence: 2,
            timeMilliseconds: 2,
            priorState: afterAssociate,
            capabilities: TraceCapabilities(),
            limits: .default,
            input: deadvertiseInput,
            localOperation: .processInbound,
            expected: TraceObservation(actions: [], rejection: nil, nextState: initialEmpty(afterAssociate))
        )
        let trace = ProtocolTrace(
            id: "inline-association-release",
            description: "inline association release",
            initialState: initialState,
            steps: [associateStep, deadvertiseStep]
        )

        let host = try await HostTraceReplayAdapter(assertExpected: false).replay(trace)
        let `static` = try await ProfileStaticTraceReplayAdapter(
            profile: .coaty3JSON,
            payloadOverride: [:],
            assertExpected: false
        ).replay(trace)
        #expect(host == `static`)

        let release = try #require(host.observations.last)
        #expect(release.rejection == nil)
        #expect(release.nextState.associationIDs.isEmpty)
        #expect(release.nextState.activeObjectIDs.isEmpty)
        #expect(release.actions.count == 2)
        #expect(release.actions.allSatisfy { $0.family == .deadvertise })
        #expect(release.actions.allSatisfy { $0.kind == "deliver" })
        #expect(release.actions.allSatisfy { $0.payload == Array(deadvertiseInput.fixturePayload.utf8) })
    }

    private func initialEmpty(_ state: TraceState) -> TraceState {
        TraceState(
            activeObjectIDs: state.activeObjectIDs,
            pendingCorrelationIDs: state.pendingCorrelationIDs,
            associationIDs: [],
            generation: state.generation
        )
    }

    /// The trace replay derives object identities with a stable FNV-1a hash.
    private static func identityText(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(
            format: "%02x%02x%02x%02x-0000-4000-8000-000000000001",
            UInt8(truncatingIfNeeded: hash >> 24),
            UInt8(truncatingIfNeeded: hash >> 16),
            UInt8(truncatingIfNeeded: hash >> 8),
            UInt8(truncatingIfNeeded: hash)
        )
    }
}
