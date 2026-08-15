// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Owns the IO association state machine: the four parallel dictionaries that
/// track which IO sources are associated with which IO actors, over which
/// routes, and the IO state observables that dispatch change events.
///
/// Extracted from `CommunicationManager` to deepen the module: the invariant
/// (source-side and actor-side maps mirror each other) is now enforced in one
/// place, and the `MutableBox` reference-type workaround is replaced with
/// value-type write-back.
///
/// Callbacks (`onSubscribe`, `onUnsubscribe`, `onIoStateDispatch`) decouple the
/// registry from `CommunicationManager`'s subscription coordinator and stream
/// infrastructure, making the registry testable in isolation.
@MainActor
internal final class IoAssociationRegistry {

    private var observedIoStateItems: [CoatyUUID: IoStateItem] = [:]
    private var ioSourceItems: [CoatyUUID: IoSourceItem] = [:]
    private var ioActorItems: [String: [CoatyUUID: [CoatyUUID]]] = [:]
    private(set) var ioNodes: [IoNode] = []

    var onSubscribe: ((String) -> Void)?
    var onUnsubscribe: ((String) -> Void)?
    var onIoStateDispatch: ((CoatyUUID, IoStateEvent) -> Void)?

    func setIoNodes(_ nodes: [IoNode]) {
        self.ioNodes = nodes
    }

    func associatingRoute(for ioSourceId: CoatyUUID) -> String? {
        ioSourceItems[ioSourceId]?.associatingRoute
    }

    func findIoPointById(objectId: CoatyUUID) -> IoPoint? {
        for ioNode in ioNodes {
            if let source = ioNode.ioSources.first(where: { $0.objectId == objectId }) {
                return source
            }
            if let actor = ioNode.ioActors.first(where: { $0.objectId == objectId }) {
                return actor
            }
        }
        return nil
    }

    func handleAssociate(
        ioSourceId: CoatyUUID,
        ioActorId: CoatyUUID,
        ioRoute: String?,
        updateRate: Int?,
        isExternalRoute: Bool?
    ) {
        let ioActor = findIoPointById(objectId: ioActorId) as? IoActor
        let isIoSourceAssociated = findIoPointById(objectId: ioSourceId) != nil
        let isIoActorAssociated = ioActor != nil

        if !isIoSourceAssociated && !isIoActorAssociated {
            return
        }

        // Actors displaced by a route change (reassociation). They must be
        // notified with their new (usually false) association state before the
        // replacement actor's state is dispatched, so state ordering stays
        // deterministic (#475).
        var displacedActorIds: [CoatyUUID] = []
        if isIoSourceAssociated {
            displacedActorIds = updateIoSourceItems(
                ioSourceId: ioSourceId, ioActorId: ioActorId,
                ioRoute: ioRoute, updateRate: updateRate
            )
        }

        if isIoActorAssociated {
            if let ioRoute {
                associateIoActorItems(
                    ioSourceId: ioSourceId, ioActor: ioActor!,
                    ioRoute: ioRoute,
                    isExternalRoute: isExternalRoute ?? false
                )
            } else {
                disassociateIoActorItems(
                    ioSourceId: ioSourceId, ioActorId: ioActorId,
                    currentIoRoute: nil, newIoRoute: nil
                )
            }
        }

        if isIoSourceAssociated, observedIoStateItems[ioSourceId] != nil {
            let source = ioSourceItems[ioSourceId]
            let hasAssociations = source != nil && !source!.actorIds.isEmpty
            let rate = source?.updateRate
            dispatchIoState(
                ioPointId: ioSourceId,
                message: IoStateEvent.with(hasAssociations: hasAssociations, updateRate: rate)
            )
        }

        // Notify every displaced actor with its current association state
        // before announcing the replacement's state (see #475). An actor's
        // state reflects any remaining associations across all routes, so a
        // displaced actor that is still fed by another source stays true.
        for actorId in displacedActorIds where observedIoStateItems[actorId] != nil {
            dispatchIoState(
                ioPointId: actorId,
                message: IoStateEvent.with(hasAssociations: actorHasAssociations(actorId))
            )
        }

        if isIoActorAssociated, observedIoStateItems[ioActorId] != nil {
            dispatchIoState(
                ioPointId: ioActorId,
                message: IoStateEvent.with(hasAssociations: actorHasAssociations(ioActorId))
            )
        }
    }

    func observeIoState(ioPointId: CoatyUUID) -> IoStateEvent {
        if let item = observedIoStateItems[ioPointId] {
            return item.currentValue
        }
        var hasAssociations = false
        var updateRate: Int?
        if let source = ioSourceItems[ioPointId] {
            hasAssociations = !source.actorIds.isEmpty
            updateRate = source.updateRate
        } else {
            hasAssociations = actorHasAssociations(ioPointId)
        }
        let value = IoStateEvent.with(hasAssociations: hasAssociations, updateRate: updateRate)
        observedIoStateItems[ioPointId] = IoStateItem(ioPointId: ioPointId, currentValue: value)
        return value
    }

    /// Returns the object IDs of all actors currently associated on the given
    /// route, i.e. the active association state for that route.
    ///
    /// - Parameter ioRoute: the MQTT route (generated or external) on which an IO
    ///   value was received.
    /// - Returns: the object IDs of every actor associated on `ioRoute`. Empty when
    ///   no actor is currently associated on the route.
    func associatedActorIds(on ioRoute: String) -> [CoatyUUID] {
        guard let items = ioActorItems[ioRoute] else { return [] }
        return Array(items.keys)
    }

    func unobserveAll() {
        for ioPointId in observedIoStateItems.keys {
            dispatchIoState(
                ioPointId: ioPointId,
                message: IoStateEvent.with(hasAssociations: false, updateRate: nil)
            )
        }
        for route in ioActorItems.keys {
            onUnsubscribe?(route)
        }
        observedIoStateItems.removeAll()
        ioSourceItems.removeAll()
        ioActorItems.removeAll()
    }

    /// Updates the source-side association map for the given associate event.
    ///
    /// Returns the object IDs of any actors displaced by a route change so the
    /// caller can notify them with their new association state (#475). The
    /// replacement actor (`ioActorId`) is never included, since it is not
    /// displaced.
    @discardableResult
    private func updateIoSourceItems(
        ioSourceId: CoatyUUID, ioActorId: CoatyUUID,
        ioRoute: String?, updateRate: Int?
    ) -> [CoatyUUID] {
        if let ioRoute {
            if ioSourceItems[ioSourceId] == nil {
                ioSourceItems[ioSourceId] = IoSourceItem(
                    associatingRoute: ioRoute,
                    actorIds: [ioActorId],
                    updateRate: updateRate
                )
                return []
            } else if var items = ioSourceItems[ioSourceId] {
                if items.associatingRoute == ioRoute {
                    if !items.actorIds.contains(ioActorId) {
                        items.actorIds.append(ioActorId)
                    }
                    items.updateRate = updateRate
                    ioSourceItems[ioSourceId] = items
                    return []
                } else {
                    let previousRoute = items.associatingRoute
                    items.associatingRoute = ioRoute
                    // Actors on the previous route are displaced by this route
                    // change, excluding the replacement (which may have been
                    // among them if it is being reassociated to the new route).
                    let displaced = items.actorIds.filter { $0 != ioActorId }
                    for actorId in items.actorIds {
                        disassociateIoActorItems(
                            ioSourceId: ioSourceId, ioActorId: actorId,
                            currentIoRoute: previousRoute, newIoRoute: nil
                        )
                    }
                    items.actorIds = [ioActorId]
                    items.updateRate = updateRate
                    ioSourceItems[ioSourceId] = items
                    return displaced
                }
            }
        } else {
            if var items = ioSourceItems[ioSourceId] {
                if let i = items.actorIds.firstIndex(of: ioActorId) {
                    items.actorIds.remove(at: i)
                }
                items.updateRate = updateRate
                if items.actorIds.isEmpty {
                    ioSourceItems.removeValue(forKey: ioSourceId)
                } else {
                    ioSourceItems[ioSourceId] = items
                }
            }
        }
        return []
    }

    private func associateIoActorItems(
        ioSourceId: CoatyUUID, ioActor: IoActor,
        ioRoute: String, isExternalRoute: Bool
    ) {
        let ioActorId = ioActor.objectId

        disassociateIoActorItems(
            ioSourceId: ioSourceId, ioActorId: ioActorId,
            currentIoRoute: nil, newIoRoute: ioRoute
        )

        if var items = ioActorItems[ioRoute] {
            if var sourceIds = items[ioActorId] {
                if !sourceIds.contains(ioSourceId) {
                    sourceIds.append(ioSourceId)
                    items[ioActorId] = sourceIds
                }
            } else {
                items[ioActorId] = [ioSourceId]
            }
            ioActorItems[ioRoute] = items
        } else {
            ioActorItems[ioRoute] = [ioActorId: [ioSourceId]]
            onSubscribe?(ioRoute)
        }
    }

    private func disassociateIoActorItems(
        ioSourceId: CoatyUUID, ioActorId: CoatyUUID,
        currentIoRoute: String?, newIoRoute: String?
    ) {
        var ioRoutesToUnsubscribe: [String] = []

        if let currentIoRoute {
            if var items = ioActorItems[currentIoRoute] {
                disassociateFromRoute(
                    items: &items, ioSourceId: ioSourceId, ioActorId: ioActorId,
                    route: (current: currentIoRoute, replacement: newIoRoute),
                    ioRoutesToUnsubscribe: &ioRoutesToUnsubscribe
                )
                ioActorItems[currentIoRoute] = items
            }
        } else {
            for route in ioActorItems.keys {
                if var items = ioActorItems[route] {
                    disassociateFromRoute(
                        items: &items, ioSourceId: ioSourceId, ioActorId: ioActorId,
                        route: (current: route, replacement: newIoRoute),
                        ioRoutesToUnsubscribe: &ioRoutesToUnsubscribe
                    )
                    ioActorItems[route] = items
                }
            }
        }

        for route in ioRoutesToUnsubscribe {
            ioActorItems.removeValue(forKey: route)
            onUnsubscribe?(route)
        }
    }

    private func disassociateFromRoute(
        items: inout [CoatyUUID: [CoatyUUID]],
        ioSourceId: CoatyUUID, ioActorId: CoatyUUID,
        route: (current: String, replacement: String?),
        ioRoutesToUnsubscribe: inout [String]
    ) {
        if let newIoRoute = route.replacement, newIoRoute == route.current {
            return
        }
        if var sourceIds = items[ioActorId] {
            sourceIds.removeAll { $0 == ioSourceId }
            if sourceIds.isEmpty {
                items.removeValue(forKey: ioActorId)
            } else {
                items[ioActorId] = sourceIds
            }
            if items.isEmpty {
                ioRoutesToUnsubscribe.append(route.current)
            }
        }
    }

    /// Whether the given actor is currently associated with at least one IO
    /// source on any route. Preferred over a route-scoped source count because
    /// an actor may stay associated with other sources while being removed from
    /// one route (#475).
    private func actorHasAssociations(_ ioActorId: CoatyUUID) -> Bool {
        ioActorItems.values.contains { $0[ioActorId] != nil }
    }

    private func dispatchIoState(ioPointId: CoatyUUID, message: IoStateEvent) {
        observedIoStateItems[ioPointId]?.currentValue = message
        onIoStateDispatch?(ioPointId, message)
    }
}

internal struct IoStateItem {
    let ioPointId: CoatyUUID
    var currentValue: IoStateEvent
}

internal struct IoSourceItem {
    var associatingRoute: String
    var actorIds: [CoatyUUID]
    var updateRate: Int?
}
