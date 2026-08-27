// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A delivery selector borrowed from the frame that produced an action.
public enum BorrowedProtocolDeliveryKey {
    /// Match every action in a capability family.
    case capability(ProtocolCapability)
    /// Match an Advertise filter.
    case advertiseFilter(ByteSlice)
    /// Match a Channel identifier.
    case channel(ByteSlice)
    /// Match an IoValue actor endpoint.
    case ioActor(UUID16)
    /// Match a response family and correlation identity.
    case correlated(ProtocolCapability, UUID16)
}

/// A delivery selector safe to store or send across an isolation boundary.
public enum OwnedProtocolDeliveryKey: Sendable, Equatable {
    /// Match every action in a capability family.
    case capability(ProtocolCapability)
    /// Match an Advertise filter.
    case advertiseFilter([UInt8])
    /// Match a Channel identifier.
    case channel([UInt8])
    /// Match an IoValue actor endpoint.
    case ioActor(UUID16)
    /// Match a response family and correlation identity.
    case correlated(ProtocolCapability, UUID16)
}

/// The canonical separator used before an outbound event-type filter.
public enum ProtocolEventTypeFilterKind: UInt8, Sendable, Equatable {
    /// A single-colon filter such as a core type, channel, or Call operation.
    case direct = 1
    /// A double-colon object-type filter.
    case objectType = 2
}

/// The target of a borrowed publication.
public enum BorrowedProtocolPublishTarget {
    /// A publication on the Coaty profile route.
    case profile(eventTypeFilter: ByteSlice?, filterKind: ProtocolEventTypeFilterKind)
    /// A publication on an exact external route.
    case associationRoute(route: ByteSlice, kind: ProtocolRouteClassification)
}

/// The target of an owned publication.
public enum OwnedProtocolPublishTarget: Sendable, Equatable {
    /// A publication on the Coaty profile route.
    case profile(eventTypeFilter: [UInt8]?, filterKind: ProtocolEventTypeFilterKind)
    /// A publication on an exact external route.
    case associationRoute(route: [UInt8], kind: ProtocolRouteClassification)
}

/// The complete delivery context borrowed from a protocol frame.
public struct BorrowedProtocolDelivery {
    /// The normalized routing key.
    public let routingKey: ProtocolRoutingKey
    /// The typed subscription selector.
    public let deliveryKey: BorrowedProtocolDeliveryKey
    /// The binding-owned route classification.
    public let routeClassification: ProtocolRouteClassification
    /// The original topic, when the action came from inbound wire data.
    public let topic: ByteSlice?
    /// The borrowed payload.
    public let payload: ByteSlice

    /// Creates a borrowed delivery context.
    public init(
        routingKey: ProtocolRoutingKey,
        deliveryKey: BorrowedProtocolDeliveryKey? = nil,
        routeClassification: ProtocolRouteClassification = .coaty,
        topic: ByteSlice? = nil,
        payload: ByteSlice
    ) {
        self.routingKey = routingKey
        self.deliveryKey = deliveryKey ?? .capability(routingKey.capability)
        self.routeClassification = routeClassification
        self.topic = topic
        self.payload = payload
    }

    /// Copies the complete delivery context.
    public borrowing func owned() -> OwnedProtocolDelivery {
        OwnedProtocolDelivery(
            routingKey: routingKey,
            deliveryKey: deliveryKey.owned(),
            routeClassification: routeClassification,
            topic: topic?.ownedBytes(),
            payload: payload.ownedBytes()
        )
    }
}

/// The complete delivery context safe to store or send.
public struct OwnedProtocolDelivery: Sendable, Equatable {
    /// The normalized routing key.
    public let routingKey: ProtocolRoutingKey
    /// The copied subscription selector.
    public let deliveryKey: OwnedProtocolDeliveryKey
    /// The binding-owned route classification.
    public let routeClassification: ProtocolRouteClassification
    /// The copied original topic.
    public let topic: [UInt8]?
    /// The copied payload.
    public let payload: [UInt8]

    /// Creates an owned delivery context.
    public init(
        routingKey: ProtocolRoutingKey,
        deliveryKey: OwnedProtocolDeliveryKey,
        routeClassification: ProtocolRouteClassification,
        topic: [UInt8]? = nil,
        payload: [UInt8]
    ) {
        self.routingKey = routingKey
        self.deliveryKey = deliveryKey
        self.routeClassification = routeClassification
        self.topic = topic
        self.payload = payload
    }
}

/// A borrowed outbound publication.
public struct BorrowedProtocolPublication {
    /// The normalized routing key.
    public let routingKey: ProtocolRoutingKey
    /// The publication target and route information.
    public let target: BorrowedProtocolPublishTarget
    /// The borrowed payload.
    public let payload: ByteSlice
    /// Whether this publication represents the logical application event.
    public let isApplicationDelivery: Bool

    /// Creates a borrowed publication.
    public init(
        routingKey: ProtocolRoutingKey,
        target: BorrowedProtocolPublishTarget,
        payload: ByteSlice,
        isApplicationDelivery: Bool = true
    ) {
        self.routingKey = routingKey
        self.target = target
        self.payload = payload
        self.isApplicationDelivery = isApplicationDelivery
    }

    /// Copies the complete publication context.
    public borrowing func owned() -> OwnedProtocolPublication {
        OwnedProtocolPublication(
            routingKey: routingKey,
            target: target.owned(),
            payload: payload.ownedBytes(),
            isApplicationDelivery: isApplicationDelivery
        )
    }
}

/// An owned outbound publication.
public struct OwnedProtocolPublication: Sendable, Equatable {
    /// The normalized routing key.
    public let routingKey: ProtocolRoutingKey
    /// The copied publication target and route information.
    public let target: OwnedProtocolPublishTarget
    /// The copied payload.
    public let payload: [UInt8]
    /// Whether this publication represents the logical application event.
    public let isApplicationDelivery: Bool

    /// Creates an owned publication.
    public init(
        routingKey: ProtocolRoutingKey,
        target: OwnedProtocolPublishTarget,
        payload: [UInt8],
        isApplicationDelivery: Bool = true
    ) {
        self.routingKey = routingKey
        self.target = target
        self.payload = payload
        self.isApplicationDelivery = isApplicationDelivery
    }
}

/// A bounded route snapshot carried by an association transition.
///
/// Association removal frames omit the route being removed. The processor
/// snapshots that route in fixed inline storage before committing removal.
public struct BorrowedProtocolRouteSnapshot {
    private var bytes: ProtocolRouteStorage
    /// Number of meaningful route bytes.
    public let length: Int

    /// Creates a bounded snapshot from borrowed route bytes.
    public init?(slice: ByteSlice) {
        guard slice.length > 0, slice.length <= ProtocolBufferConfig.maxRouteBytes else { return nil }
        var storage = ProtocolRouteStorage(repeating: 0)
        for index in 0..<slice.length { storage[index] = slice.byte(at: index) ?? 0 }
        self.bytes = storage
        self.length = slice.length
    }

    /// Creates a snapshot from already-filled fixed storage.
    init(length: Int, storage: ProtocolRouteStorage) {
        self.bytes = storage
        self.length = length
    }

    /// Returns one route byte by index.
    public func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < length else { return nil }
        return bytes[index]
    }

    /// Copies the snapshot into an owned route.
    public borrowing func owned() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(length)
        for index in 0..<length { result.append(bytes[index]) }
        return result
    }
}

/// The kind of association transition represented by an action.
public enum ProtocolIoAssociationChange: Sendable, Equatable {
    /// A new source-to-actor association.
    case established
    /// An existing association changed route or metadata.
    case updated
    /// An existing association was removed.
    case removed
}

/// A borrowed association transition with its complete delivery context.
public struct BorrowedIoAssociationTransition {
    /// The delivery context for the Associate frame.
    public let delivery: BorrowedProtocolDelivery
    /// The source endpoint identity.
    public let sourceID: UUID16
    /// The actor endpoint identity.
    public let actorID: UUID16
    /// The transition kind.
    public let change: ProtocolIoAssociationChange
    /// The resulting or removed exact route, when one exists.
    public let route: BorrowedProtocolRouteSnapshot?
    /// The route classification.
    public let routeClassification: ProtocolRouteClassification

    /// Creates a borrowed association transition.
    public init(
        delivery: BorrowedProtocolDelivery,
        sourceID: UUID16,
        actorID: UUID16,
        change: ProtocolIoAssociationChange,
        route: BorrowedProtocolRouteSnapshot?,
        routeClassification: ProtocolRouteClassification
    ) {
        self.delivery = delivery
        self.sourceID = sourceID
        self.actorID = actorID
        self.change = change
        self.route = route
        self.routeClassification = routeClassification
    }

    /// Copies the complete association transition.
    public borrowing func owned() -> OwnedIoAssociationTransition {
        OwnedIoAssociationTransition(
            delivery: delivery.owned(),
            sourceID: sourceID,
            actorID: actorID,
            change: change,
            route: route?.owned(),
            routeClassification: routeClassification
        )
    }
}

/// An owned association transition.
public struct OwnedIoAssociationTransition: Sendable, Equatable {
    /// The copied delivery context for the Associate frame.
    public let delivery: OwnedProtocolDelivery
    /// The source endpoint identity.
    public let sourceID: UUID16
    /// The actor endpoint identity.
    public let actorID: UUID16
    /// The transition kind.
    public let change: ProtocolIoAssociationChange
    /// The copied resulting or removed route.
    public let route: [UInt8]?
    /// The route classification.
    public let routeClassification: ProtocolRouteClassification

    /// Creates an owned association transition.
    public init(
        delivery: OwnedProtocolDelivery,
        sourceID: UUID16,
        actorID: UUID16,
        change: ProtocolIoAssociationChange,
        route: [UInt8]?,
        routeClassification: ProtocolRouteClassification
    ) {
        self.delivery = delivery
        self.sourceID = sourceID
        self.actorID = actorID
        self.change = change
        self.route = route
        self.routeClassification = routeClassification
    }
}

/// A borrowed external-route lifecycle transition.
public struct BorrowedExternalRouteTransition {
    /// The source endpoint identity.
    public let sourceID: UUID16
    /// The actor endpoint identity.
    public let actorID: UUID16
    /// The exact external route retained in bounded borrowed storage.
    public let route: BorrowedProtocolRouteSnapshot

    /// Creates a borrowed external-route transition.
    public init(sourceID: UUID16, actorID: UUID16, route: ByteSlice) {
        self.sourceID = sourceID
        self.actorID = actorID
        guard let route = BorrowedProtocolRouteSnapshot(slice: route) else {
            preconditionFailure("external route must be a non-empty bounded route")
        }
        self.route = route
    }

    /// Creates a lifecycle transition from a processor-owned route snapshot.
    public init(sourceID: UUID16, actorID: UUID16, route: BorrowedProtocolRouteSnapshot) {
        self.sourceID = sourceID
        self.actorID = actorID
        self.route = route
    }

    /// Copies the transition before crossing an ownership boundary.
    public borrowing func owned() -> OwnedExternalRouteTransition {
        OwnedExternalRouteTransition(sourceID: sourceID, actorID: actorID, route: route.owned())
    }
}

/// An owned external-route lifecycle transition.
public struct OwnedExternalRouteTransition: Sendable, Equatable {
    /// The source endpoint identity.
    public let sourceID: UUID16
    /// The actor endpoint identity.
    public let actorID: UUID16
    /// The copied exact external route.
    public let route: [UInt8]

    /// Creates an owned external-route transition.
    public init(sourceID: UUID16, actorID: UUID16, route: [UInt8]) {
        self.sourceID = sourceID
        self.actorID = actorID
        self.route = route
    }
}

/// A normalized protocol action produced by the portable processor.
public enum BorrowedProtocolAction {
    /// Deliver an inbound frame to a protocol consumer.
    case deliver(BorrowedProtocolDelivery)
    /// Publish an outbound frame through a binding.
    case publish(BorrowedProtocolPublication)
    /// Record an association transition.
    case associationChanged(BorrowedIoAssociationTransition)
    /// Activate an exact external route.
    case externalRouteActivated(BorrowedExternalRouteTransition)
    /// Deactivate an exact external route.
    case externalRouteDeactivated(BorrowedExternalRouteTransition)

    /// Materializes an owned action before an asynchronous boundary.
    public borrowing func owned() -> OwnedProtocolAction {
        switch self {
        case .deliver(let delivery): return .deliver(delivery.owned())
        case .publish(let publication): return .publish(publication.owned())
        case .associationChanged(let transition): return .associationChanged(transition.owned())
        case .externalRouteActivated(let transition): return .externalRouteActivated(transition.owned())
        case .externalRouteDeactivated(let transition): return .externalRouteDeactivated(transition.owned())
        }
    }
}

/// An owned, sendable normalized protocol action.
public enum OwnedProtocolAction: Sendable, Equatable {
    /// An owned inbound delivery.
    case deliver(OwnedProtocolDelivery)
    /// An owned outbound publication.
    case publish(OwnedProtocolPublication)
    /// An owned association transition.
    case associationChanged(OwnedIoAssociationTransition)
    /// An owned external-route activation.
    case externalRouteActivated(OwnedExternalRouteTransition)
    /// An owned external-route deactivation.
    case externalRouteDeactivated(OwnedExternalRouteTransition)
}

private extension BorrowedProtocolDeliveryKey {
    borrowing func owned() -> OwnedProtocolDeliveryKey {
        switch self {
        case .capability(let value): return .capability(value)
        case .advertiseFilter(let value): return .advertiseFilter(value.ownedBytes())
        case .channel(let value): return .channel(value.ownedBytes())
        case .ioActor(let value): return .ioActor(value)
        case .correlated(let capability, let identity): return .correlated(capability, identity)
        }
    }
}

private extension BorrowedProtocolPublishTarget {
    borrowing func owned() -> OwnedProtocolPublishTarget {
        switch self {
        case .profile(let filter, let kind): return .profile(eventTypeFilter: filter?.ownedBytes(), filterKind: kind)
        case .associationRoute(let route, let kind): return .associationRoute(route: route.ownedBytes(), kind: kind)
        }
    }
}

private extension ByteSlice {
    borrowing func ownedBytes() -> [UInt8] {
        withBytes { pointer, length in
            Array(UnsafeBufferPointer(
                start: pointer.assumingMemoryBound(to: UInt8.self),
                count: length
            ))
        }
    }
}
