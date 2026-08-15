// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Unit tests for the IO association state machine in
/// ``IoAssociationRegistry``.
///
/// The registry is decoupled from the communication manager via its
/// `onSubscribe`/`onUnsubscribe`/`onIoStateDispatch` callbacks, so the state
/// machine is testable in isolation without a broker. These tests exercise the
/// source-side and actor-side association invariants, route change handling,
/// IO state observation, and teardown.
@MainActor
struct IoAssociationRegistryTests {

    // MARK: - Fixtures

    private func makeSource(_ id: String, route: String? = nil) -> IoSource {
        IoSource(
            valueType: "com.example.Temperature",
            updateRate: 500,
            externalRoute: route,
            name: "Source \(id)",
            objectId: CoatyUUID(uuidString: id)!
        )
    }

    private func makeActor(_ id: String) -> IoActor {
        IoActor(
            valueType: "com.example.Temperature",
            name: "Actor \(id)",
            objectId: CoatyUUID(uuidString: id)!
        )
    }

    private func makeRegistry(
        sources: [IoSource] = [],
        actors: [IoActor] = []
    ) -> (registry: IoAssociationRegistry, subscribe: LockedStringCollector, unsubscribe: LockedStringCollector) {
        let registry = IoAssociationRegistry()
        let sourceIds = sources.map(\.objectId)
        let actorIds = actors.map(\.objectId)
        let node = IoNode(
            coreType: .IoNode,
            objectType: IoNode.objectType,
            objectId: CoatyUUID(),
            name: "Test Node",
            ioSources: sources,
            ioActors: actors
        )
        registry.setIoNodes([node])

        let subscribe = LockedStringCollector()
        let unsubscribe = LockedStringCollector()
        registry.onSubscribe = { subscribe.append($0) }
        registry.onUnsubscribe = { unsubscribe.append($0) }

        // Sanity: the fixture UUIDs above are valid.
        #expect(sourceIds.count == sources.count)
        #expect(actorIds.count == actors.count)
        _ = sourceIds
        _ = actorIds

        return (registry, subscribe, unsubscribe)
    }

    // MARK: - Association

    @Test
    func associateSourceWithActorEnrichesSourceRoute() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actor])

        registry.handleAssociate(
            ioSourceId: source.objectId,
            ioActorId: actor.objectId,
            ioRoute: "route-1",
            updateRate: 500,
            isExternalRoute: false
        )

        #expect(registry.associatingRoute(for: source.objectId) == "route-1")
    }

    @Test
    func associatingUnknownSourceOrActorIsIgnored() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, subscribe, _) = makeRegistry(sources: [source], actors: [actor])

        // Neither known → no-op, no subscribe.
        registry.handleAssociate(
            ioSourceId: CoatyUUID(),
            ioActorId: CoatyUUID(),
            ioRoute: "route-ghost",
            updateRate: nil,
            isExternalRoute: nil
        )
        #expect(subscribe.values.isEmpty)
        #expect(registry.associatingRoute(for: source.objectId) == nil)
    }

    @Test
    func repeatedAssociateSameRouteDoesNotDuplicateSourcesOrSubscribe() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, subscribe, _) = makeRegistry(sources: [source], actors: [actor])

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )

        // Same route: actor set has one source, subscribe fired once.
        #expect(subscribe.values == ["route-1"])
        #expect(registry.associatingRoute(for: source.objectId) == "route-1")
    }

    @Test
    func routeChangeReassociatesAndUnsubscribesOldRoute() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, subscribe, unsubscribe) = makeRegistry(sources: [source], actors: [actor])

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-2", updateRate: 500, isExternalRoute: false
        )

        #expect(subscribe.values == ["route-1", "route-2"])
        #expect(unsubscribe.values == ["route-1"])
        #expect(registry.associatingRoute(for: source.objectId) == "route-2")
    }

    @Test
    func disassociationWithoutRouteRemovesAssociationAndUnsubscribes() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, subscribe, unsubscribe) = makeRegistry(sources: [source], actors: [actor])

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        // Disassociate (ioRoute nil).
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: nil, updateRate: nil, isExternalRoute: nil
        )

        #expect(subscribe.values == ["route-1"])
        #expect(unsubscribe.values == ["route-1"])
        #expect(registry.associatingRoute(for: source.objectId) == nil)
    }

    // MARK: - IO state

    @Test
    func observeIoStateReflectsAssociationPresence() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actor])

        let initial = registry.observeIoState(ioPointId: source.objectId)
        #expect(initial.eventData.hasAssociations() == false)

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )

        let after = registry.observeIoState(ioPointId: source.objectId)
        #expect(after.eventData.hasAssociations() == true)
        #expect(after.eventData.updateRate() == 500)
    }

    @Test
    func associationDispatchesIoStateWhenObserved() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actor])
        let dispatches = LockedStringCollector()
        registry.onIoStateDispatch = { _, event in
            dispatches.append("\(event.eventData.hasAssociations())")
        }

        _ = registry.observeIoState(ioPointId: source.objectId)
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )

        // The source (observed) gets a dispatch reflecting the new association.
        #expect(dispatches.values.contains("true"))
    }

    @Test
    func unobserveAllDispatchesDetachmentAndUnsubscribesRoutes() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, _, unsubscribe) = makeRegistry(sources: [source], actors: [actor])
        let dispatches = LockedStringCollector()
        registry.onIoStateDispatch = { _, event in
            dispatches.append("\(event.eventData.hasAssociations())")
        }

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        _ = registry.observeIoState(ioPointId: source.objectId)
        registry.unobserveAll()

        #expect(unsubscribe.values == ["route-1"])
        // Detachment dispatch carries hasAssociations=false.
        #expect(dispatches.values.contains("false"))
    }

    @Test
    func unobserveAllClearsStateForRestart() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, subscribe, unsubscribe) = makeRegistry(sources: [source], actors: [actor])
        let dispatches = LockedStringCollector()
        registry.onIoStateDispatch = { _, event in
            dispatches.append("\(event.eventData.hasAssociations())")
        }

        _ = registry.observeIoState(ioPointId: source.objectId)
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        #expect(subscribe.values == ["route-1"])
        #expect(dispatches.values == ["true"])

        registry.unobserveAll()
        #expect(unsubscribe.values == ["route-1"])
        #expect(dispatches.values == ["true", "false"])
        #expect(registry.associatingRoute(for: source.objectId) == nil)

        // A restart must establish a new route subscription and avoid sending
        // state to the observer that was torn down above.
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 750, isExternalRoute: false
        )
        #expect(subscribe.values == ["route-1", "route-1"])
        #expect(dispatches.values == ["true", "false"])

        let restartedState = registry.observeIoState(ioPointId: source.objectId)
        #expect(restartedState.eventData.hasAssociations())
        #expect(restartedState.eventData.updateRate() == 750)
    }

    // MARK: - Reassociation (issue #475)

    /// A dispatch collector that records both the point ID and the association
    /// flag, so tests can assert per-actor notification and deterministic
    /// ordering.
    @MainActor
    private final class LockedDispatchCollector {
        private var storage: [String] = []

        var values: [String] { storage }

        func append(_ pointId: CoatyUUID, hasAssociations: Bool) {
            storage.append("\(pointId.string):\(hasAssociations)")
        }

        func clear() {
            storage.removeAll()
        }
    }

    private func makeObservedDispatches(_ registry: IoAssociationRegistry) -> LockedDispatchCollector {
        let dispatches = LockedDispatchCollector()
        registry.onIoStateDispatch = { ioPointId, event in
            dispatches.append(ioPointId, hasAssociations: event.eventData.hasAssociations())
        }
        return dispatches
    }

    @Test
    func reassociationDispatchesFalseStateToDisplacedActor() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actorA = makeActor("20000000-0000-4000-8000-000000000002")
        let actorB = makeActor("20000000-0000-4000-8000-000000000003")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actorA, actorB])

        // Observe actor A, actor B, and the source so their state transitions
        // are all dispatched.
        _ = registry.observeIoState(ioPointId: source.objectId)
        _ = registry.observeIoState(ioPointId: actorA.objectId)
        _ = registry.observeIoState(ioPointId: actorB.objectId)
        let dispatches = makeObservedDispatches(registry)

        // 1. Associate actor A with the source.
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorA.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        #expect(dispatches.values.contains("\(actorA.objectId.string):true"))

        // 2. Reassociate the source to actor B -> actor A is displaced.
        dispatches.clear()
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorB.objectId,
            ioRoute: "route-2", updateRate: 500, isExternalRoute: false
        )

        // Displaced actor A must receive a false state transition.
        #expect(dispatches.values.contains("\(actorA.objectId.string):false"))
        // The replacement actor B becomes active.
        #expect(dispatches.values.contains("\(actorB.objectId.string):true"))
        // Source state reflects the new association.
        #expect(dispatches.values.contains("\(source.objectId.string):true"))
    }

    @Test
    func reassociationDispatchesFalseStateToAllDisplacedActors() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actorA = makeActor("20000000-0000-4000-8000-000000000002")
        let actorB = makeActor("20000000-0000-4000-8000-000000000003")
        let actorC = makeActor("20000000-0000-4000-8000-000000000004")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actorA, actorB, actorC])

        _ = registry.observeIoState(ioPointId: actorA.objectId)
        _ = registry.observeIoState(ioPointId: actorB.objectId)
        _ = registry.observeIoState(ioPointId: actorC.objectId)
        let dispatches = makeObservedDispatches(registry)

        // Two actors share the source on one route.
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorA.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorB.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        dispatches.clear()

        // Reassociate the source to actor C -> actors A and B are displaced.
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorC.objectId,
            ioRoute: "route-2", updateRate: 500, isExternalRoute: false
        )

        #expect(dispatches.values.contains("\(actorA.objectId.string):false"))
        #expect(dispatches.values.contains("\(actorB.objectId.string):false"))
        #expect(dispatches.values.contains("\(actorC.objectId.string):true"))
    }

    @Test
    func displacedActorRetainsTrueStateWhenStillAssociatedWithAnotherSource() async {
        let source1 = makeSource("10000000-0000-4000-8000-000000000001", route: nil)
        let source2 = makeSource("30000000-0000-4000-8000-000000000005")
        let actorA = makeActor("20000000-0000-4000-8000-000000000002")
        let actorB = makeActor("20000000-0000-4000-8000-000000000003")
        let (registry, _, _) = makeRegistry(
            sources: [source1, source2], actors: [actorA, actorB]
        )

        _ = registry.observeIoState(ioPointId: actorA.objectId)
        _ = registry.observeIoState(ioPointId: actorB.objectId)
        let dispatches = makeObservedDispatches(registry)

        // Actor A is fed by both source1 (route-1) and source2 (route-2).
        registry.handleAssociate(
            ioSourceId: source1.objectId, ioActorId: actorA.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        registry.handleAssociate(
            ioSourceId: source2.objectId, ioActorId: actorA.objectId,
            ioRoute: "route-2", updateRate: 500, isExternalRoute: false
        )
        dispatches.clear()

        // source1 is reassociated to actor B; actor A is displaced from source1
        // but remains associated with source2, so its state must stay true.
        registry.handleAssociate(
            ioSourceId: source1.objectId, ioActorId: actorB.objectId,
            ioRoute: "route-3", updateRate: 500, isExternalRoute: false
        )

        #expect(dispatches.values.contains("\(actorA.objectId.string):true"))
        #expect(dispatches.values.contains("\(actorB.objectId.string):true"))
    }

    @Test
    func displacedActorStateIsDispatchedBeforeReplacementActorState() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actorA = makeActor("20000000-0000-4000-8000-000000000002")
        let actorB = makeActor("20000000-0000-4000-8000-000000000003")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actorA, actorB])

        _ = registry.observeIoState(ioPointId: actorA.objectId)
        _ = registry.observeIoState(ioPointId: actorB.objectId)
        let dispatches = makeObservedDispatches(registry)

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorA.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        dispatches.clear()

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorB.objectId,
            ioRoute: "route-2", updateRate: 500, isExternalRoute: false
        )

        // Actor A (displaced) must be notified before actor B (replacement).
        let ordering = dispatches.values
        let displacedAIndex = ordering.firstIndex(of: "\(actorA.objectId.string):false")
        let replacementBIndex = ordering.firstIndex(of: "\(actorB.objectId.string):true")
        #expect(displacedAIndex != nil)
        #expect(replacementBIndex != nil)
        #expect(displacedAIndex! < replacementBIndex!)
    }

    // MARK: - IO value routing

    @Test
    func associatedActorIdsReflectsActiveAssociationsOnRoute() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actor])

        // No association yet -> no actor on the route.
        #expect(registry.associatedActorIds(on: "route-1").isEmpty)

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )

        #expect(registry.associatedActorIds(on: "route-1") == [actor.objectId])
        // A different route has no associated actors.
        #expect(registry.associatedActorIds(on: "route-other").isEmpty)
    }

    @Test
    func associatedActorIdsReturnsAllActorsOnSharedRoute() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actorA = makeActor("20000000-0000-4000-8000-000000000002")
        let actorB = makeActor("20000000-0000-4000-8000-000000000003")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actorA, actorB])

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorA.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actorB.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )

        let ids = registry.associatedActorIds(on: "route-1")
        #expect(ids.contains(actorA.objectId))
        #expect(ids.contains(actorB.objectId))
        #expect(ids.count == 2)
    }

    @Test
    func associatedActorIdsRemovesActorAfterDisassociation() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actor])

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        #expect(registry.associatedActorIds(on: "route-1") == [actor.objectId])

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: nil, updateRate: nil, isExternalRoute: nil
        )

        #expect(registry.associatedActorIds(on: "route-1").isEmpty)
    }

    @Test
    func associatedActorIdsClearsOnRestart() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let (registry, _, _) = makeRegistry(sources: [source], actors: [actor])

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 500, isExternalRoute: false
        )
        #expect(registry.associatedActorIds(on: "route-1") == [actor.objectId])

        // Teardown clears all association state; a later restart must rebuild it.
        registry.unobserveAll()
        #expect(registry.associatedActorIds(on: "route-1").isEmpty)

        registry.handleAssociate(
            ioSourceId: source.objectId, ioActorId: actor.objectId,
            ioRoute: "route-1", updateRate: 750, isExternalRoute: false
        )
        #expect(registry.associatedActorIds(on: "route-1") == [actor.objectId])
    }

    // MARK: - Lookup

    @Test
    func findIoPointByIdFindsSourcesAndActorsAcrossNodes() async {
        let source = makeSource("10000000-0000-4000-8000-000000000001")
        let actor = makeActor("20000000-0000-4000-8000-000000000002")
        let registry = IoAssociationRegistry()
        registry.setIoNodes([
            IoNode(
                coreType: .IoNode,
                objectType: IoNode.objectType,
                objectId: CoatyUUID(),
                name: "Node",
                ioSources: [source],
                ioActors: [actor]
            ),
        ])

        #expect(registry.findIoPointById(objectId: source.objectId)?.coreType == .IoSource)
        #expect(registry.findIoPointById(objectId: actor.objectId)?.coreType == .IoActor)
        #expect(registry.findIoPointById(objectId: CoatyUUID()) == nil)
    }
}

/// Collects strings on the main actor for callback assertions.
@MainActor
private final class LockedStringCollector {
    private var storage: [String] = []

    var values: [String] { storage }

    func append(_ value: String) {
        storage.append(value)
    }
}
