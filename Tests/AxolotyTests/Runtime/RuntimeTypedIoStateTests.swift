// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyObjectModel
import AxolotyWire
import Testing
@testable import Axoloty

@Suite("Runtime typed IO state")
struct RuntimeTypedIoStateTests {
    @Test("publication completion commits only the matching execution generation")
    func generationCheckedCompletion() throws {
        let fixture = try makeFixture(policy: .immediate)
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        let plan = state.preparePublication(
            [UInt8]([116, 114, 117, 101]), representation: .json, from: fixture.source,
            association: association, nowMS: 10, dispatchAvailable: true
        )
        guard case .publish = plan else {
            Issue.record("an associated immediate source should prepare a publication")
            return
        }

        state.clearTransportState()
        _ = state.completePublication(plan, outcome: .accepted, nowMS: 10, association: association)
        #expect(state.endpoint(at: 0)?.inFlight == false)
        #expect(state.endpoint(at: 0)?.pending == nil)
    }

    @Test("transport completion requires the exact typed attempt token")
    func attemptCheckedCompletion() throws {
        let fixture = try makeFixture(policy: .immediate)
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        let plan = state.preparePublication(
            [1], representation: .json, from: fixture.source, association: association,
            nowMS: 0, dispatchAvailable: true
        )
        guard case let .publish(token, _, _) = plan else {
            Issue.record("an immediate publication should produce a token")
            return
        }
        _ = state.completePublication(plan, outcome: .accepted, nowMS: 0, association: association)
        let stale = RuntimeTypedIoPublicationToken(
            slot: token.slot, generation: token.generation,
            executionGeneration: token.executionGeneration, attempt: token.attempt &+ 1
        )
        #expect(state.completeTransportPublication(stale) == false)
        #expect(state.endpoint(at: 0)?.inFlight == true)
        #expect(state.completeTransportPublication(token) == true)
        #expect(state.endpoint(at: 0)?.inFlight == false)
    }

    @Test("latest policy retains one replacement and preserves the first emission timing")
    func latestReplacement() throws {
        let fixture = try makeFixture(policy: .latest(atMostEveryMS: 100))
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        let first = state.preparePublication(
            [1], representation: .json, from: fixture.source, association: association,
            nowMS: 0, dispatchAvailable: true
        )
        _ = state.completePublication(first, outcome: .accepted, nowMS: 0, association: association)
        let second = state.preparePublication(
            [2], representation: .json, from: fixture.source, association: association,
            nowMS: 1, dispatchAvailable: true
        )
        guard case .queueLatest = second else {
            Issue.record("latest should prepare a replacement while throttled")
            return
        }
        _ = state.completePublication(second, outcome: nil, nowMS: 1, association: association)
        #expect(state.endpoint(at: 0)?.pending == [2])
    }

    @Test("pending latest capacity is global but replacement remains admissible")
    func pendingCapacity() throws {
        let fixture = try makeFixture(policy: .latest(atMostEveryMS: 100), endpointCount: 2)
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        let first = state.preparePublication(
            [1], representation: .json, from: fixture.sources[0], association: association,
            nowMS: 0, dispatchAvailable: true
        )
        _ = state.completePublication(first, outcome: .accepted, nowMS: 0, association: association)
        let queued = state.preparePublication(
            [2], representation: .json, from: fixture.sources[0], association: association,
            nowMS: 1, dispatchAvailable: true
        )
        _ = state.completePublication(queued, outcome: nil, nowMS: 1, association: association)
        let rejected = state.preparePublication(
            [3], representation: .json, from: fixture.sources[1], association: association,
            nowMS: 1, dispatchAvailable: false
        )
        guard case .receipt(.rejected(.capacityExceeded)) = rejected else {
            Issue.record("a second source should be rejected when pending capacity is full")
            return
        }
        let replacement = state.preparePublication(
            [4], representation: .json, from: fixture.sources[0], association: association,
            nowMS: 2, dispatchAvailable: true
        )
        _ = state.completePublication(replacement, outcome: nil, nowMS: 2, association: association)
        #expect(state.endpoint(at: 0)?.pending == [4])
    }

    @Test("throttle admission retains its timing rules")
    func throttleAdmission() throws {
        let fixture = try makeFixture(policy: .throttle(forMS: 100))
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        let first = state.preparePublication(
            [1], representation: .json, from: fixture.source, association: association,
            nowMS: 10, dispatchAvailable: true
        )
        guard case let .publish(token, _, _) = first else {
            Issue.record("throttle should admit its first value")
            return
        }
        _ = state.completePublication(first, outcome: .accepted, nowMS: 10, association: association)
        let completed = state.completeTransportPublication(token)
        #expect(completed)
        let throttled = state.preparePublication(
            [2], representation: .json, from: fixture.source, association: association,
            nowMS: 11, dispatchAvailable: true
        )
        guard case .receipt(.throttled) = throttled else {
            Issue.record("throttle should reject values before its interval")
            return
        }
        guard case .publish = state.preparePublication(
            [3], representation: .json, from: fixture.source, association: association,
            nowMS: 110, dispatchAvailable: true
        ) else {
            Issue.record("throttle should become eligible at its interval")
            return
        }
    }

    @Test("immediate admission publishes when transport capacity is available")
    func immediateAdmission() throws {
        let fixture = try makeFixture(policy: .immediate)
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        guard case .publish = state.preparePublication(
            [1], representation: .json, from: fixture.source, association: association,
            nowMS: 0, dispatchAvailable: true
        ) else {
            Issue.record("immediate policy should admit an associated value")
            return
        }
    }

    @Test("capacity rejection of a latest publication returns queued latest")
    func capacityRejectionQueuesLatest() throws {
        let fixture = try makeFixture(policy: .latest(atMostEveryMS: 100))
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        let plan = state.preparePublication(
            [1], representation: .json, from: fixture.source, association: association,
            nowMS: 0, dispatchAvailable: true
        )
        guard case .publish = plan else { Issue.record("latest should initially publish"); return }
        let completion = state.completePublication(
            plan, outcome: .rejected(.capacityExceeded), nowMS: 0, association: association
        )
        #expect(completion?.receipt == .queuedLatest)
        #expect(state.endpoint(at: 0)?.pending == [1])
    }

    @Test("endpoint handles reject foreign, stale, and wrong-role provenance")
    func endpointProvenance() throws {
        let fixture = try makeFixture(policy: .immediate)
        let foreign = IoSource<DynamicIoValue>(
            registryID: ObjectID(uuid: UUID16(bytes: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 9))),
            slot: 0, generation: 1, id: fixture.source.id, representation: .json
        )
        let stale = IoSource<DynamicIoValue>(
            registryID: fixture.sourceRegistryID, slot: 0, generation: 2,
            id: fixture.source.id, representation: .json
        )
        let wrongRole = IoActor<DynamicIoValue>(
            registryID: fixture.sourceRegistryID, slot: 0, generation: 1,
            id: fixture.source.id, representation: .json
        )
        #expect(fixture.state.sourceSlot(foreign) == nil)
        #expect(fixture.state.sourceSlot(stale) == nil)
        #expect(fixture.state.actorSlot(wrongRole) == nil)
    }

    @Test("observer changes are generation-driven and strict overflow is reported")
    func observerOverflow() throws {
        let fixture = try makeFixture(policy: .immediate)
        var state = fixture.state
        let pair = AsyncStream<IoAssociationState>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let initial = IoAssociationState(generation: 0)
        _ = try state.addObserver(
            sourceID: fixture.source.id, actorID: nil, snapshot: initial,
            buffering: .failAfterDrop(capacity: 1), continuation: pair.continuation
        )
        pair.continuation.yield(initial)
        var overflow = 0
        state.notifyObservers(
            sourceState: { _ in IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1) },
            actorState: { _ in IoAssociationState() },
            onStrictOverflow: { _ in overflow += 1 },
            sourceIDs: [fixture.source.id], actorIDs: []
        )
        #expect(overflow == 1)
    }

    @Test("reconnect invalidates scheduled callbacks")
    func reconnectInvalidatesCallbacks() throws {
        let fixture = try makeFixture(policy: .latest(atMostEveryMS: 100))
        let association = IoAssociationState(generation: 1, hasAssociations: true, associationCount: 1)
        var state = fixture.state
        let first = state.preparePublication(
            [1], representation: .json, from: fixture.source, association: association,
            nowMS: 0, dispatchAvailable: true
        )
        _ = state.completePublication(first, outcome: .accepted, nowMS: 0, association: association)
        let queued = state.preparePublication(
            [2], representation: .json, from: fixture.source, association: association,
            nowMS: 1, dispatchAvailable: true
        )
        let completion = state.completePublication(queued, outcome: nil, nowMS: 1, association: association)
        guard let request = completion?.flushRequest else {
            Issue.record("latest replacement should produce a flush request")
            return
        }
        state.installFlushTask(Task {}, for: request)
        state.clearTransportState()
        #expect(state.takeFlushTask(for: request.token) == false)
    }
}

private struct RuntimeTypedIoFixture {
    let state: RuntimeTypedIoState
    let source: IoSource<DynamicIoValue>
    let sources: [IoSource<DynamicIoValue>]
    let sourceRegistryID: ObjectID
}

private func makeFixture(policy: IoPublicationPolicy, endpointCount: Int = 1) throws -> RuntimeTypedIoFixture {
    let capacities = try RuntimeCapacities(ioEndpoints: endpointCount, ioPendingLatest: 1)
    let registryID = ObjectID(uuid: UUID16(bytes: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1)))
    var registrations = RuntimeRegistrations(capacities: capacities, registryID: registryID)
    var sources: [IoSource<DynamicIoValue>] = []
    for index in 0..<endpointCount {
        let endpointID = ObjectID(uuid: UUID16(bytes: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(index + 2))))
        registrations.ioEndpointRegistrations.append(RuntimeIoEndpointRegistration(
            id: endpointID, role: .source, representation: .json, objectBytes: BoundedIoBytes(),
            publication: policy, recommendedUpdateRateMS: nil, handler: nil
        ))
        registrations.endpointGenerations.append(1)
        sources.append(IoSource(registryID: registryID, slot: UInt16(index), generation: 1, id: endpointID, representation: .json))
    }
    return RuntimeTypedIoFixture(
        state: RuntimeTypedIoState(registrations: registrations), source: sources[0],
        sources: sources, sourceRegistryID: registryID
    )
}
