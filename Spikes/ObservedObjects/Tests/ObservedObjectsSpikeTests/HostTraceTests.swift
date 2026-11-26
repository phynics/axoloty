// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyObjectModel
import AxolotyWire
import Testing
@testable import ObservedObjectsSpike

@Suite("Observed objects broker-free host trace")
struct HostTraceTests {
    @Test(
        "reset quarantines passive evidence and admits only a checked late reply",
        arguments: WireProfile.allCases
    )
    func resetQuarantinesPassiveEvidenceAndAdmitsOnlyCheckedReply(
        profile: WireProfile
    ) async throws(HostTraceError) {
        try await withHostTraceHarness(profile: profile) { (harness: HostTraceHarness) async throws(HostTraceError) in
            try await runResetTrace(harness)
        }
    }

    /// Replays one known ID with no broker, no network, and no SPI surface.
    ///
    /// The trace holds the application drains, processes a pre-reset Advertise
    /// and a correlated Resolve, forces a transport reset, then releases the
    /// drains around a new exact-ID Discover with a fresh correlation.
    private func runResetTrace(_ harness: HostTraceHarness) async throws(HostTraceError) {
        let profile = harness.profile
        let clock = ContinuousClock()
        let runtime = harness.runtime

        let initial = await runtime.diagnosticsSnapshot()
        #expect(initial.lifecycleState == .running)
        let initialPublished = await harness.transport.publishedRoutes()
        #expect(!initialPublished.contains(where: {
            HostTraceWire.eventType(in: $0) == HostTraceWire.Event.discover.rawValue
        }))
        #expect(await harness.transport.startCountValue() == 1)

        // A new attachment starts empty. It existed before the reset so the
        // reset is the only thing that can make its passive coverage uncertain.
        var attachment = try HostTraceAttachment(snapshot: initial)
        #expect(attachment.snapshot(at: 90).evidence == .unobserved)
        #expect(attachment.snapshot(at: 90).uncertainty.isEmpty)

        // The application leaves both streams undrained while the runtime
        // accepts one Advertise and a valid pre-reset Resolve.
        let discoverA = try HostTraceWire.discoverPayload(
            profile: profile,
            identity: HostTraceFixture.pump
        )
        let receiptA = await runtime.request(.discover(
            correlationID: HostTraceFixture.oldCorrelation.uuid,
            payload: discoverA,
            timeoutMS: 100
        ), nowMS: 90)
        #expect(receiptA == .accepted)
        try await hostTraceWait("pre-reset Discover stays pending") {
            await runtime.diagnosticsSnapshot().pendingRequests == 1
        }
        try await hostTraceWait("pre-reset Discover reaches the transport") {
            let routes = await harness.transport.publishedRoutes()
            return routes.contains {
                HostTraceWire.eventType(in: $0) == HostTraceWire.Event.discover.rawValue
                    && HostTraceWire.correlation(in: $0) == HostTraceFixture.oldCorrelation.hyphenated
            }
        }

        let beforeRelease = await runtime.diagnosticsSnapshot()
        await harness.transport.inject(
            route: HostTraceWire.route(
                profile: profile,
                event: .advertise,
                source: HostTraceFixture.responder
            ),
            payload: try HostTraceWire.advertisePayload(profile: profile),
            nowMS: 100
        )
        await harness.transport.inject(
            route: HostTraceWire.route(
                profile: profile,
                event: .resolve,
                source: HostTraceFixture.responder,
                correlation: HostTraceFixture.oldCorrelation
            ),
            payload: try HostTraceWire.resolvePayload(
                profile: profile,
                identity: HostTraceFixture.pump
            ),
            nowMS: 101
        )
        try await hostTraceWait("pre-reset frames are processed") {
            let snapshot = await runtime.diagnosticsSnapshot()
            return snapshot.responsesReceived == beforeRelease.responsesReceived + 1
                && snapshot.activeObjects == beforeRelease.activeObjects + 1
        }
        let pendingBeforeReset = await runtime.diagnosticsSnapshot()
        #expect(pendingBeforeReset.pendingRequests == 1)
        #expect(pendingBeforeReset.presenceUncertain == false)

        // Force a reconnect while the application has not drained any event.
        await runtime.reconnect()
        try await hostTraceWait("reconnect reaches a new running epoch") {
            let state = await runtime.state()
            let snapshot = await runtime.diagnosticsSnapshot()
            return state == .running
                && snapshot.lifecycle.transportEpoch > initial.lifecycle.transportEpoch
        }
        let afterReset = await runtime.diagnosticsSnapshot()
        #expect(afterReset.lifecycle.transportEpoch == initial.lifecycle.transportEpoch + 1)
        #expect(afterReset.lastReconnect?.cause == .requested)
        #expect(afterReset.presenceResets == initial.presenceResets + 1)
        #expect(afterReset.pendingRequests == 0)
        #expect(afterReset.cancelledRequests == initial.cancelledRequests + 1)
        #expect(afterReset.presenceUncertain)
        #expect(await harness.transport.startCountValue() == 2)

        try attachment.observe(afterReset)
        #expect(attachment.snapshot(at: 190).uncertainty.contains(.continuityLoss))

        // Submit the new exact-ID Discover with a fresh correlation. The
        // attempt is reserved before submission so an early reply could stage.
        let baseline = afterReset
        var attempt = HostTraceAttempt.reserve(
            correlationID: HostTraceFixture.newCorrelation.uuid,
            objectID: HostTraceFixture.pump.uuid,
            snapshot: baseline,
            deadline: clock.now + .seconds(5)
        )
        #expect(HostTraceFixture.newCorrelation.uuid != HostTraceFixture.oldCorrelation.uuid)
        let discoverB = try HostTraceWire.discoverPayload(
            profile: profile,
            identity: HostTraceFixture.pump
        )
        #expect(HostTraceWire.discoverObjectID(in: discoverB, profile: profile) == HostTraceFixture.pump.uuid)
        let receiptB = await runtime.request(.discover(
            correlationID: HostTraceFixture.newCorrelation.uuid,
            payload: discoverB,
            timeoutMS: 100
        ), nowMS: 190)
        #expect(receiptB == .accepted)
        try await hostTraceWait("new exact-ID Discover reaches the transport") {
            let routes = await harness.transport.publishedRoutes()
            return routes.contains {
                HostTraceWire.eventType(in: $0) == HostTraceWire.Event.discover.rawValue
                    && HostTraceWire.correlation(in: $0) == HostTraceFixture.newCorrelation.hyphenated
            }
        }
        let newDiscover = await harness.transport.publishedMessages().last {
            HostTraceWire.eventType(in: $0.route) == HostTraceWire.Event.discover.rawValue
                && HostTraceWire.correlation(in: $0.route) == HostTraceFixture.newCorrelation.hyphenated
        }
        guard let newDiscover else {
            throw .invariant("new exact-ID Discover was not published")
        }
        #expect(HostTraceWire.correlation(in: newDiscover.route) == HostTraceFixture.newCorrelation.hyphenated)
        #expect(HostTraceWire.discoverObjectID(in: newDiscover.payload, profile: profile) == HostTraceFixture.pump.uuid)

        // Release the held drains. The pre-reset Advertise is still in the
        // queue but the attachment now treats passive coverage as uncertain.
        let oldAdvertise = try await hostTraceNextEvent(from: harness.advertise) {
            $0.family == .advertise
                && $0.context.provenance == .transport
                && $0.context.sourceID == HostTraceFixture.responder.uuid
        }
        #expect(oldAdvertise.context.receiptTimeMS == 100)
        let passive = try attachment.applyPassive(oldAdvertise, profile: profile, within: 90...200)
        #expect(!passive)
        #expect(attachment.snapshot(at: 200).evidence == .unobserved)
        #expect(attachment.snapshot(at: 200).uncertainty.contains(.continuityLoss))

        // The old correlated Resolve is drained too, but it cannot enter the
        // new attempt because its correlation belongs to the cancelled window.
        let oldResolve = try await hostTraceNextEvent(from: harness.resolve) {
            $0.family == .resolve && $0.context.correlationID == HostTraceFixture.oldCorrelation.uuid
        }
        let oldOffer = attempt.offer(
            oldResolve,
            profile: profile,
            snapshot: afterReset,
            now: clock.now
        )
        #expect(oldOffer == .rejected(.correlationMismatch))
        #expect(attempt.staged.isEmpty)

        // A reply that carries the new correlation but the wrong exact ID is
        // observed and refused without consuming a candidate slot.
        let wrongPayload = try HostTraceWire.resolvePayload(
            profile: profile,
            identity: HostTraceFixture.otherPump
        )
        let beforeWrong = await runtime.diagnosticsSnapshot()
        await harness.transport.inject(
            route: HostTraceWire.route(
                profile: profile,
                event: .resolve,
                source: HostTraceFixture.responder,
                correlation: HostTraceFixture.newCorrelation
            ),
            payload: wrongPayload,
            nowMS: 200
        )
        try await hostTraceWait("wrong-object reply is processed") {
            await runtime.diagnosticsSnapshot().responsesReceived == beforeWrong.responsesReceived + 1
        }
        let wrongResolve = try await hostTraceNextEvent(from: harness.resolve) {
            $0.family == .resolve && $0.context.correlationID == HostTraceFixture.newCorrelation.uuid
        }
        #expect(HostTraceWire.objectID(in: wrongResolve, profile: profile) == HostTraceFixture.otherPump.uuid)
        let wrongOffer = attempt.offer(
            wrongResolve,
            profile: profile,
            snapshot: await runtime.diagnosticsSnapshot(),
            now: clock.now
        )
        #expect(wrongOffer == .rejected(.objectIDMismatch))
        #expect(attempt.staged.isEmpty)

        // Only the properly checked matching reply is admitted.
        let correctPayload = try HostTraceWire.resolvePayload(
            profile: profile,
            identity: HostTraceFixture.pump
        )
        let beforeCorrect = await runtime.diagnosticsSnapshot()
        await harness.transport.inject(
            route: HostTraceWire.route(
                profile: profile,
                event: .resolve,
                source: HostTraceFixture.responder,
                correlation: HostTraceFixture.newCorrelation
            ),
            payload: correctPayload,
            nowMS: 201
        )
        try await hostTraceWait("matching reply is processed") {
            await runtime.diagnosticsSnapshot().responsesReceived == beforeCorrect.responsesReceived + 1
        }
        let correctResolve = try await hostTraceNextEvent(from: harness.resolve) {
            $0.family == .resolve && $0.context.correlationID == HostTraceFixture.newCorrelation.uuid
        }
        let correctOffer = attempt.offer(
            correctResolve,
            profile: profile,
            snapshot: await runtime.diagnosticsSnapshot(),
            now: clock.now
        )
        #expect(correctOffer == .staged)
        #expect(attempt.staged.count == 1)
        // The drain can stage a reply before the caller handles its receipt.
        #expect(!attempt.accepted)
        let acceptedB = attempt.accept(receiptB)
        #expect(acceptedB)
        let admittedSnapshot = await runtime.diagnosticsSnapshot()
        let outcome = attempt.finish(snapshot: admittedSnapshot, now: clock.now)
        guard case .admitted(let sample) = outcome else {
            throw .invariant("expected one admitted sample, got \(outcome)")
        }
        #expect(sample.observation.objectID == ObjectID(uuid: HostTraceFixture.pump.uuid))
        #expect(sample.observation.source.rawValue == HostTraceFixture.responder.uuid)
        #expect(sample.correlationID == HostTraceFixture.newCorrelation.uuid)
        #expect(sample.epoch == afterReset.lifecycle.transportEpoch)
        #expect(attempt.closed)
        guard let tick = receiptTick(sample.receiptTimeMS, within: 190...205) else {
            throw .invariant("response receipt is outside the binding's clock window")
        }
        try attachment.apply(sample.observation, at: tick)
        let projection = attachment.snapshot(at: 205)
        guard case .observed(let candidate) = projection.evidence else {
            throw .invariant("expected the checked Resolve in the projection")
        }
        #expect(candidate.bytes == sample.observation.bytes)
        #expect(candidate.delivery == .resolve)
        #expect(candidate.observedAtTick == 201)
        #expect(projection.ageTicks == 4)
        #expect(projection.uncertainty.contains(.continuityLoss))
        #expect(attachment.snapshot(at: 211).freshness == .stale)
        #expect(attachment.snapshot(at: 221).evidence == .expired)

        // Request exit releases the correlation.
        let beforeCancel = await runtime.diagnosticsSnapshot()
        #expect(await runtime.cancel(correlationID: HostTraceFixture.newCorrelation.uuid))
        let afterCancel = await runtime.diagnosticsSnapshot()
        #expect(afterCancel.pendingRequests == 0)
        #expect(afterCancel.cancelledRequests == beforeCancel.cancelledRequests + 1)

        // An intact, accepted, empty window is explicitly `.noSample`.
        let emptyDiscover = try HostTraceWire.discoverPayload(
            profile: profile,
            identity: HostTraceFixture.pump
        )
        var emptyAttempt = HostTraceAttempt.reserve(
            correlationID: HostTraceFixture.emptyCorrelation.uuid,
            objectID: HostTraceFixture.pump.uuid,
            snapshot: afterCancel,
            deadline: clock.now + .seconds(5)
        )
        let emptyReceipt = await runtime.request(.discover(
            correlationID: HostTraceFixture.emptyCorrelation.uuid,
            payload: emptyDiscover,
            timeoutMS: 100
        ), nowMS: 220)
        #expect(emptyReceipt == .accepted)
        let acceptedEmpty = emptyAttempt.accept(emptyReceipt)
        #expect(acceptedEmpty)
        #expect(await nextHostTraceEvent(from: harness.resolve, timeout: .milliseconds(50)) { _ in true } == nil)
        let emptyFinal = await runtime.diagnosticsSnapshot()
        let emptyOutcome = emptyAttempt.finish(snapshot: emptyFinal, now: clock.now)
        #expect(emptyOutcome == .noSample)
        #expect(emptyAttempt.closed)
        #expect(await runtime.cancel(correlationID: HostTraceFixture.emptyCorrelation.uuid))
        #expect(await runtime.diagnosticsSnapshot().pendingRequests == 0)

        // A cancelled window is interrupted, and the runtime correlation is
        // released rather than left pending.
        let cancelledDiscover = try HostTraceWire.discoverPayload(
            profile: profile,
            identity: HostTraceFixture.pump
        )
        var cancelledAttempt = HostTraceAttempt.reserve(
            correlationID: HostTraceFixture.cancelledCorrelation.uuid,
            objectID: HostTraceFixture.pump.uuid,
            snapshot: await runtime.diagnosticsSnapshot(),
            deadline: clock.now + .seconds(5)
        )
        let cancelledReceipt = await runtime.request(.discover(
            correlationID: HostTraceFixture.cancelledCorrelation.uuid,
            payload: cancelledDiscover,
            timeoutMS: 100
        ), nowMS: 230)
        #expect(cancelledReceipt == .accepted)
        let acceptedCancelled = cancelledAttempt.accept(cancelledReceipt)
        #expect(acceptedCancelled)
        let cancelledOutcome = cancelledAttempt.cancel()
        #expect(cancelledOutcome == .interrupted(.cancelled))
        #expect(await runtime.cancel(correlationID: HostTraceFixture.cancelledCorrelation.uuid))
        #expect(await runtime.diagnosticsSnapshot().pendingRequests == 0)

        // Loss counters are compared conservatively against the post-reset
        // baseline; any movement would have interrupted rather than admitted
        // or reported `.noSample`.
        let finalSnapshot = await runtime.diagnosticsSnapshot()
        #expect(finalSnapshot.dispatchSaturation == baseline.dispatchSaturation)
        #expect(finalSnapshot.ingressSaturation == baseline.ingressSaturation)
        #expect(finalSnapshot.handlerSaturation == baseline.handlerSaturation)
        #expect(finalSnapshot.malformedFrames == baseline.malformedFrames)
        #expect(finalSnapshot.transportFailures == baseline.transportFailures)
        #expect(finalSnapshot.receiveDrops == baseline.receiveDrops)
        #expect(finalSnapshot.oversizedSamples == baseline.oversizedSamples)
        #expect(finalSnapshot.presenceResets == baseline.presenceResets)
    }
}
