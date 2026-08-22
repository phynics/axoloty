// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The normalized selector used by protocol consumers after topic parsing.
public enum ProtocolDeliveryKey {
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

/// The finite action kinds exposed by the portable processor boundary.
public enum ProtocolActionKind: UInt8, Sendable, Equatable {
    /// Deliver an inbound frame to a protocol consumer.
    case deliver = 1
    /// Publish an outbound frame through a binding.
    case publish = 2
    /// Record an association transition.
    case associate = 3
    /// Record a disassociation transition.
    case disassociate = 4
}

/// A synchronous action that borrows its payload from a frame buffer.
///
/// Borrowed actions are intentionally non-sendable. Consumers must call
/// ``owned()`` before storing, awaiting, or crossing an isolation boundary.
public struct BorrowedProtocolAction {
    /// The normalized action kind.
    public let kind: ProtocolActionKind
    /// The action routing key.
    public let routingKey: ProtocolRoutingKey
    /// The normalized delivery selector.
    public let deliveryKey: ProtocolDeliveryKey
    /// The binding-owned association route classification for this action.
    public let routeClassification: ProtocolRouteClassification
    /// The optional outbound event-type filter, such as a Call operation name.
    public let eventTypeFilter: ByteSlice?
    /// The original borrowed topic, when the action came from inbound wire data.
    public let topic: ByteSlice?
    /// The borrowed action payload.
    public let payload: ByteSlice

    /// Creates a borrowed action.
    public init(
        kind: ProtocolActionKind,
        routingKey: ProtocolRoutingKey,
        payload: ByteSlice,
        deliveryKey: ProtocolDeliveryKey? = nil,
        topic: ByteSlice? = nil,
        routeClassification: ProtocolRouteClassification = .coaty,
        eventTypeFilter: ByteSlice? = nil
    ) {
        self.kind = kind
        self.routingKey = routingKey
        self.deliveryKey = deliveryKey ?? .capability(routingKey.capability)
        self.routeClassification = routeClassification
        self.eventTypeFilter = eventTypeFilter
        self.topic = topic
        self.payload = payload
    }

    /// Materializes an owned action before an asynchronous boundary.
    public func owned() -> OwnedProtocolAction {
        let copied = payload.withBytes { pointer, length in
            Array(UnsafeBufferPointer(
                start: pointer.assumingMemoryBound(to: UInt8.self),
                count: length
            ))
        }
        let copiedFilter = eventTypeFilter?.withBytes { pointer, length in
            Array(UnsafeBufferPointer(
                start: pointer.assumingMemoryBound(to: UInt8.self),
                count: length
            ))
        }
        return OwnedProtocolAction(kind: kind, routingKey: routingKey, payload: copied, eventTypeFilter: copiedFilter)
    }
}

/// An owned, sendable normalized protocol action.
public struct OwnedProtocolAction: Sendable, Equatable {
    /// The normalized action kind.
    public let kind: ProtocolActionKind
    /// The action routing key.
    public let routingKey: ProtocolRoutingKey
    /// The owned action payload.
    public let payload: [UInt8]
    /// The copied outbound event-type filter, when one was supplied.
    public let eventTypeFilter: [UInt8]?

    /// Creates an owned action.
    public init(
        kind: ProtocolActionKind,
        routingKey: ProtocolRoutingKey,
        payload: [UInt8],
        eventTypeFilter: [UInt8]? = nil
    ) {
        self.kind = kind
        self.routingKey = routingKey
        self.payload = payload
        self.eventTypeFilter = eventTypeFilter
    }
}
