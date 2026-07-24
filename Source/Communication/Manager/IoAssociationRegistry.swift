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

        if isIoSourceAssociated {
            updateIoSourceItems(
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

        if isIoActorAssociated, observedIoStateItems[ioActorId] != nil {
            let sourceCount = ioRoute.flatMap { ioActorItems[$0]?[ioActorId]?.count } ?? 0
            dispatchIoState(
                ioPointId: ioActorId,
                message: IoStateEvent.with(hasAssociations: sourceCount > 0)
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
            hasAssociations = ioActorItems.values.contains { $0[ioPointId] != nil }
        }
        let value = IoStateEvent.with(hasAssociations: hasAssociations, updateRate: updateRate)
        observedIoStateItems[ioPointId] = IoStateItem(ioPointId: ioPointId, currentValue: value)
        return value
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
    }

    private func updateIoSourceItems(
        ioSourceId: CoatyUUID, ioActorId: CoatyUUID,
        ioRoute: String?, updateRate: Int?
    ) {
        if let ioRoute {
            if ioSourceItems[ioSourceId] == nil {
                ioSourceItems[ioSourceId] = IoSourceItem(
                    associatingRoute: ioRoute,
                    actorIds: [ioActorId],
                    updateRate: updateRate
                )
            } else if var items = ioSourceItems[ioSourceId] {
                if items.associatingRoute == ioRoute {
                    if !items.actorIds.contains(ioActorId) {
                        items.actorIds.append(ioActorId)
                    }
                } else {
                    let previousRoute = items.associatingRoute
                    items.associatingRoute = ioRoute
                    for actorId in items.actorIds {
                        disassociateIoActorItems(
                            ioSourceId: ioSourceId, ioActorId: actorId,
                            currentIoRoute: previousRoute, newIoRoute: nil
                        )
                    }
                    items.actorIds = [ioActorId]
                }
                items.updateRate = updateRate
                ioSourceItems[ioSourceId] = items
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
                    route: currentIoRoute, newIoRoute: newIoRoute,
                    ioRoutesToUnsubscribe: &ioRoutesToUnsubscribe
                )
                ioActorItems[currentIoRoute] = items
            }
        } else {
            for route in ioActorItems.keys {
                if var items = ioActorItems[route] {
                    disassociateFromRoute(
                        items: &items, ioSourceId: ioSourceId, ioActorId: ioActorId,
                        route: route, newIoRoute: newIoRoute,
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
        route: String, newIoRoute: String?,
        ioRoutesToUnsubscribe: inout [String]
    ) {
        if let newIoRoute, newIoRoute == route {
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
                ioRoutesToUnsubscribe.append(route)
            }
        }
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
