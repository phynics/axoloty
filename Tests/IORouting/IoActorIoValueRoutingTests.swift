// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// End-to-end regression for issue #473: externally received IO values must be
/// routed to the actors currently associated on their source route, rather
/// than only being broadcast globally.
///
/// The routing decision is made by reading the active association state in
/// ``IoAssociationRegistry`` (route -> associated actor IDs) at the point an
/// IO value arrives. These tests drive that path through the
/// ``CommunicationManager``: they configure a known actor on the registry,
/// associate it, then deliver an external IO value via the manager's transport
/// delegate callback and assert the value reaches the actor's per-actor
/// stream and not an unassociated actor's stream.
@MainActor
struct IoActorIoValueRoutingTests {

    // MARK: - Fixtures

    /// Awaits the next value on a MainActor-isolated stream box, returning `nil`
    /// if no value arrives within `timeout`. Kept on the main actor (the box is
    /// `@unchecked Sendable`) so the iterator is not crossed into a nonisolated
    /// closure, unlike ``nextValue(_:timeout:)`` which is used only where an
    /// eventual delivery is expected.
    @MainActor
    private func nextValueOrNil(
        _ box: AsyncStreamBox<IoValueEventSnapshot>,
        timeout: Duration = .seconds(5)
    ) async throws -> IoValueEventSnapshot? {
        try await withThrowingTaskGroup(of: IoValueEventSnapshot?.self) { group in
            group.addTask {
                await box.iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            guard let result = try await group.next() else {
                return nil
            }
            group.cancelAll()
            return result
        }
    }

    private func makeActor(_ id: String, valueType: String = "com.example.Temperature") -> IoActor {
        IoActor(
            valueType: valueType,
            name: "Actor \(id)",
            objectId: CoatyUUID(uuidString: id)!
        )
    }

    /// Builds a manager whose registry is configured with the given actors in a
    /// single IO node, so association state can be established without a broker.
    @MainActor
    private func makeManagerWithActors(_ actors: [IoActor]) -> CommunicationManager? {
        let manager = makeManager()
        let node = IoNode(
            coreType: .IoNode,
            objectType: IoNode.objectType,
            objectId: CoatyUUID(),
            name: "Test Node",
            ioSources: [],
            ioActors: actors
        )
        manager.ioRegistry.setIoNodes([node])
        return manager
    }

    @MainActor
    private func associate(
        _ manager: CommunicationManager,
        sourceId: CoatyUUID,
        actor: IoActor,
        route: String?
    ) {
        manager.ioRegistry.handleAssociate(
            ioSourceId: sourceId,
            ioActorId: actor.objectId,
            ioRoute: route,
            updateRate: 250,
            isExternalRoute: route.map { _ in true }
        )
    }

    // MARK: - Delivery to associated actor

    @Test
    func externalValueReachesAssociatedActor() async throws {
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let manager = try #require(makeManagerWithActors([actor]))
        let sourceId = try #require(CoatyUUID(uuidString: "10000000-0000-4000-8000-000000000001"))
        let route = "external/wire-compat-v1/io-external-1"
        associate(manager, sourceId: sourceId, actor: actor, route: route)

        let stream = await manager.observeIoValuesForActor(actor)
        var iterator = stream.makeAsyncIterator()

        // The transport's delegate callback delivers an external IO value on the
        // associated route.
        manager.didReceiveIoValue(topic: route, payload: [0x01, 0x02, 0x03])

        let value: IoValueEventSnapshot = try await nextValue(&iterator, timeout: .seconds(5))
        #expect(value.topic == route)
        #expect(value.payload == [0x01, 0x02, 0x03])
    }

    @Test
    func externalValueDoesNotReachUnassociatedActor() async throws {
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let manager = try #require(makeManagerWithActors([actor]))
        let sourceId = try #require(CoatyUUID(uuidString: "10000000-0000-4000-8000-000000000001"))
        // No association is established for this actor.
        _ = sourceId

        let stream = await manager.observeIoValuesForActor(actor)
        let iterator = stream.makeAsyncIterator()

        // A value published on any route must not reach an actor that is not
        // associated on that route.
        manager.didReceiveIoValue(topic: "external/wire-compat-v1/io-external-1", payload: [0x01])

        let value = try await nextValueOrNil(AsyncStreamBox(iterator), timeout: .milliseconds(500))
        #expect(value == nil)
    }

    @Test
    func externalValueFanOutsToAllActorsOnSharedRoute() async throws {
        let actorA = makeActor("20000000-0000-4000-8000-000000000002")
        let actorB = makeActor("20000000-0000-4000-8000-000000000003")
        let manager = try #require(makeManagerWithActors([actorA, actorB]))
        let sourceId = try #require(CoatyUUID(uuidString: "10000000-0000-4000-8000-000000000001"))
        let route = "external/wire-compat-v1/io-external-1"
        associate(manager, sourceId: sourceId, actor: actorA, route: route)
        associate(manager, sourceId: sourceId, actor: actorB, route: route)

        let streamA = await manager.observeIoValuesForActor(actorA)
        var iteratorA = streamA.makeAsyncIterator()
        let streamB = await manager.observeIoValuesForActor(actorB)
        var iteratorB = streamB.makeAsyncIterator()

        manager.didReceiveIoValue(topic: route, payload: [0xAA])

        let valueA: IoValueEventSnapshot = try await nextValue(&iteratorA, timeout: .seconds(5))
        let valueB: IoValueEventSnapshot = try await nextValue(&iteratorB, timeout: .seconds(5))
        #expect(valueA == valueB)
        #expect(valueB.topic == route)
    }

    @Test
    func externalRouteValueReachesAssociatedActor() async throws {
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let manager = try #require(makeManagerWithActors([actor]))
        let sourceId = try #require(CoatyUUID(uuidString: "10000000-0000-4000-8000-000000000001"))
        let route = "external/wire-compat-v1/io-external-1"
        associate(manager, sourceId: sourceId, actor: actor, route: route)

        let stream = await manager.observeIoValuesForActor(actor)
        let iterator = stream.makeAsyncIterator()

        // An external (non-Coaty) source publishes on the associated raw route;
        // the transport delivers it via the raw-message delegate callback.
        manager.didReceiveRawMQTTMessage(topic: route, payload: [0xDE, 0xAD])

        let value = try await nextValueOrNil(AsyncStreamBox(iterator), timeout: .seconds(5))
        #expect(value?.topic == route)
        #expect(value?.payload == [0xDE, 0xAD])
    }

    @Test
    func nonIoRawMessageDoesNotReachActorWhenUnassociated() async throws {
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let manager = try #require(makeManagerWithActors([actor]))

        let stream = await manager.observeIoValuesForActor(actor)
        let iterator = stream.makeAsyncIterator()
        // A raw message on a route with no associated actor is a no-op.
        manager.didReceiveRawMQTTMessage(topic: "some/other/topic", payload: [0x01])

        let value = try await nextValueOrNil(AsyncStreamBox(iterator), timeout: .milliseconds(500))
        #expect(value == nil)
    }

    // MARK: - Restart behavior

    @Test
    func externalValueDeliveredAgainAfterRestartReassociation() async throws {
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let manager = try #require(makeManagerWithActors([actor]))
        let sourceId = try #require(CoatyUUID(uuidString: "10000000-0000-4000-8000-000000000001"))
        let route = "external/wire-compat-v1/io-external-1"

        associate(manager, sourceId: sourceId, actor: actor, route: route)

        // Establish an observer and verify delivery while associated.
        let initialIterator = (await manager.observeIoValuesForActor(actor)).makeAsyncIterator()
        manager.didReceiveIoValue(topic: route, payload: [0x01])
        let first = try await nextValueOrNil(AsyncStreamBox(initialIterator), timeout: .seconds(5))
        #expect(first?.payload == [0x01])

        // A manager restart tears down association state; a value arriving on the
        // (now unassociated) route must be dropped.
        manager.ioRegistry.unobserveAll()
        let droppedIterator = (await manager.observeIoValuesForActor(actor)).makeAsyncIterator()
        manager.didReceiveIoValue(topic: route, payload: [0x02])
        let dropped = try await nextValueOrNil(AsyncStreamBox(droppedIterator), timeout: .milliseconds(500))
        #expect(dropped == nil)

        // Reassociate after restart: delivery resumes.
        associate(manager, sourceId: sourceId, actor: actor, route: route)
        let restartedIterator = (await manager.observeIoValuesForActor(actor)).makeAsyncIterator()
        manager.didReceiveIoValue(topic: route, payload: [0x03])
        let restarted = try await nextValueOrNil(AsyncStreamBox(restartedIterator), timeout: .seconds(5))
        #expect(restarted?.payload == [0x03])
    }
}