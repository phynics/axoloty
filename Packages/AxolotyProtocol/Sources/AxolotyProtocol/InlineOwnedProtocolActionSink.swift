// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A fixed inline action sink that owns every byte until synchronous drain.
///
/// Action metadata is copied per slot. Primary payload bytes are retained once
/// in a bounded arena and reused when a fan-out batch references equal bytes.
/// ``visit(at:_:)`` materializes borrowed views only for the duration of its nonescaping body.
/// This makes the sink suitable for runtimes that return to their caller
/// between protocol processing and action delivery.
public struct InlineOwnedProtocolActionSink<let capacity: Int, let payloadCapacity: Int>: ~Copyable, ProtocolActionSink {
    private var slots: InlineArray<capacity, InlineOwnedProtocolActionSlot?>
    private var payloads: InlineArray<payloadCapacity, UInt8>
    private var payloadBytesUsed: Int
    private var used: Int
    private var reserved: Int

    /// Creates an empty owning action sink.
    public init() {
        slots = InlineArray(repeating: nil)
        payloads = InlineArray(repeating: 0)
        payloadBytesUsed = 0
        used = 0
        reserved = 0
    }

    /// Number of actions currently retained by the sink.
    public var count: Int { used }
    /// Maximum unique primary-payload bytes retained between drains.
    public var maximumPayloadBytes: Int { payloadCapacity }

    /// Number of unreserved action slots.
    public var remainingCapacity: Int { capacity - used - reserved }

    /// Reserves the complete action count for one atomic processor operation.
    ///
    /// - Parameter actionCount: Number of protocol-valid actions that will be
    ///   appended by the operation.
    /// - Returns: `true` when every action slot is reserved. A failed
    ///   reservation leaves the sink unchanged.
    public mutating func preflight(actionCount: Int) -> Bool {
        guard reserved == 0, actionCount >= 0,
              actionCount <= capacity - used else { return false }
        reserved = actionCount
        return true
    }

    /// Deep-copies one preflighted action into the next inline slot.
    ///
    /// - Parameter action: A protocol-valid action whose borrowed bytes remain
    ///   caller-owned.
    /// - Returns: `true` when the complete action was copied. Invalid byte
    ///   bounds or a missing reservation leave retained slots unchanged.
    public mutating func append(_ action: BorrowedProtocolAction) -> Bool {
        guard reserved > 0, used < capacity,
              var slot = InlineOwnedProtocolActionSlot(copying: action) else {
            return false
        }
        if let payload = Self.payload(of: action) {
            guard let retained = retain(payload) else { return false }
            slot.setPrimary(offset: retained.offset, length: retained.length)
        }
        slots[used] = slot
        used += 1
        reserved -= 1
        return true
    }

    /// Visits one retained action through call-scoped borrowed views.
    ///
    /// - Parameters:
    ///   - index: Zero-based retained action index.
    ///   - body: Nonescaping visitor. The action and every byte slice become
    ///     invalid when this call returns.
    /// - Returns: `true` when `index` identified a retained action.
    public borrowing func visit(
        at index: Int,
        _ body: (BorrowedProtocolAction) -> Void
    ) -> Bool {
        guard index >= 0, index < used, let slot = slots[index] else {
            return false
        }
        withUnsafeBytes(of: payloads) { payloadBytes in
            slot.visit(primaryBytes: payloadBytes, body)
        }
        return true
    }

    /// Removes all retained actions and outstanding reservations.
    public mutating func removeAll() {
        for index in 0..<used { slots[index] = nil }
        used = 0
        reserved = 0
        payloadBytesUsed = 0
    }

    private mutating func retain(_ bytes: ByteSlice) -> (offset: Int, length: Int)? {
        guard bytes.length >= 0, bytes.length <= payloadCapacity else { return nil }
        if bytes.length == 0 { return (0, 0) }

        for index in 0..<used {
            guard let slot = slots[index], slot.primaryLength == bytes.length else { continue }
            var equal = true
            for byteIndex in 0..<bytes.length where
                payloads[slot.primaryOffset + byteIndex] != bytes.byte(at: byteIndex)
            {
                equal = false
                break
            }
            if equal { return (slot.primaryOffset, slot.primaryLength) }
        }

        guard bytes.length <= payloadCapacity - payloadBytesUsed else { return nil }
        let offset = payloadBytesUsed
        for index in 0..<bytes.length {
            payloads[offset + index] = bytes.byte(at: index) ?? 0
        }
        payloadBytesUsed += bytes.length
        return (offset, bytes.length)
    }

    private static func payload(of action: BorrowedProtocolAction) -> ByteSlice? {
        switch action {
        case .deliver(let delivery): delivery.payload
        case .publish(let publication): publication.payload
        case .associationChanged(let transition): transition.delivery.payload
        case .externalRouteActivated, .externalRouteDeactivated: nil
        }
    }
}

private enum InlineOwnedProtocolActionKind: UInt8 {
    case deliver
    case publish
    case associationChanged
    case externalRouteActivated
    case externalRouteDeactivated
}

private enum InlineOwnedDeliveryKeyKind: UInt8 {
    case capability
    case advertiseFilter
    case channel
    case ioActor
    case correlated
}

private enum InlineOwnedPublishTargetKind: UInt8 {
    case profile
    case associationRoute
}

private struct InlineOwnedProtocolActionSlot {
    private var kind: InlineOwnedProtocolActionKind
    private var routingKey: ProtocolRoutingKey?
    private var deliveryKeyKind: InlineOwnedDeliveryKeyKind
    private var deliveryCapability: ProtocolCapability?
    private var deliveryIdentity: UUID16
    private var routeClassification: ProtocolRouteClassification
    private var topicPresent: Bool
    private var publishTargetKind: InlineOwnedPublishTargetKind
    private var filterKind: ProtocolEventTypeFilterKind
    private var applicationDelivery: Bool
    private var sourceID: UUID16
    private var actorID: UUID16
    private var associationChange: ProtocolIoAssociationChange
    private var associationRoutePresent: Bool
    private(set) var primaryOffset: Int
    private(set) var primaryLength: Int
    private var secondaryLength: Int
    private var tertiaryLength: Int
    private var quaternaryLength: Int
    private var secondary: InlineArray<128, UInt8>
    private var tertiary: InlineArray<128, UInt8>
    private var quaternary: InlineArray<128, UInt8>

    init?(copying action: BorrowedProtocolAction) {
        kind = .deliver
        routingKey = nil
        deliveryKeyKind = .capability
        deliveryCapability = nil
        deliveryIdentity = .zero
        routeClassification = .unrelated
        topicPresent = false
        publishTargetKind = .profile
        filterKind = .direct
        applicationDelivery = false
        sourceID = .zero
        actorID = .zero
        associationChange = .established
        associationRoutePresent = false
        primaryOffset = 0
        primaryLength = 0
        secondaryLength = 0
        tertiaryLength = 0
        quaternaryLength = 0
        secondary = InlineArray(repeating: 0)
        tertiary = InlineArray(repeating: 0)
        quaternary = InlineArray(repeating: 0)

        switch action {
        case .deliver(let delivery):
            kind = .deliver
            guard copy(delivery: delivery) else { return nil }
        case .publish(let publication):
            kind = .publish
            routingKey = publication.routingKey
            applicationDelivery = publication.isApplicationDelivery
            switch publication.target {
            case .profile(let filter, let kind):
                publishTargetKind = .profile
                filterKind = kind
                if let filter {
                    guard Self.copy(filter, into: &secondary, length: &secondaryLength) else {
                        return nil
                    }
                    topicPresent = true
                }
            case .associationRoute(let route, let classification):
                publishTargetKind = .associationRoute
                routeClassification = classification
                guard route.length > 0,
                      Self.copy(route, into: &secondary, length: &secondaryLength) else {
                    return nil
                }
            }
        case .associationChanged(let transition):
            kind = .associationChanged
            sourceID = transition.sourceID
            actorID = transition.actorID
            associationChange = transition.change
            routeClassification = transition.routeClassification
            guard copy(delivery: transition.delivery) else { return nil }
            if let route = transition.route {
                guard Self.copy(route, into: &quaternary, length: &quaternaryLength) else {
                    return nil
                }
                associationRoutePresent = true
            }
        case .externalRouteActivated(let transition):
            kind = .externalRouteActivated
            sourceID = transition.sourceID
            actorID = transition.actorID
            guard Self.copy(transition.route, into: &secondary, length: &secondaryLength) else {
                return nil
            }
        case .externalRouteDeactivated(let transition):
            kind = .externalRouteDeactivated
            sourceID = transition.sourceID
            actorID = transition.actorID
            guard Self.copy(transition.route, into: &secondary, length: &secondaryLength) else {
                return nil
            }
        }
    }

    mutating func setPrimary(offset: Int, length: Int) {
        primaryOffset = offset
        primaryLength = length
    }

    borrowing func visit(
        primaryBytes: UnsafeRawBufferPointer,
        _ body: (BorrowedProtocolAction) -> Void
    ) {
        let snapshot = copy self
        withUnsafeBytes(of: snapshot.secondary) { secondaryBytes in
            withUnsafeBytes(of: snapshot.tertiary) { tertiaryBytes in
                withUnsafeBytes(of: snapshot.quaternary) { quaternaryBytes in
                    let primarySlice = Self.slice(
                        primaryBytes,
                        offset: snapshot.primaryOffset,
                        length: snapshot.primaryLength
                    )
                    let secondarySlice = Self.slice(secondaryBytes, length: snapshot.secondaryLength)
                    let tertiarySlice = Self.slice(tertiaryBytes, length: snapshot.tertiaryLength)
                    let quaternarySlice = Self.slice(quaternaryBytes, length: snapshot.quaternaryLength)
                    body(snapshot.materialize(
                        primary: primarySlice,
                        secondary: secondarySlice,
                        tertiary: tertiarySlice,
                        quaternary: quaternarySlice
                    ))
                }
            }
        }
    }

    private mutating func copy(delivery: BorrowedProtocolDelivery) -> Bool {
        routingKey = delivery.routingKey
        routeClassification = delivery.routeClassification
        if let topic = delivery.topic {
            guard Self.copy(topic, into: &secondary, length: &secondaryLength) else {
                return false
            }
            topicPresent = true
        }
        switch delivery.deliveryKey {
        case .capability(let capability):
            deliveryKeyKind = .capability
            deliveryCapability = capability
        case .advertiseFilter(let filter):
            deliveryKeyKind = .advertiseFilter
            guard Self.copy(filter, into: &tertiary, length: &tertiaryLength) else {
                return false
            }
        case .channel(let channel):
            deliveryKeyKind = .channel
            guard Self.copy(channel, into: &tertiary, length: &tertiaryLength) else {
                return false
            }
        case .ioActor(let actor):
            deliveryKeyKind = .ioActor
            deliveryIdentity = actor
        case .correlated(let capability, let correlation):
            deliveryKeyKind = .correlated
            deliveryCapability = capability
            deliveryIdentity = correlation
        }
        return true
    }

    private borrowing func materialize(
        primary: ByteSlice,
        secondary: ByteSlice,
        tertiary: ByteSlice,
        quaternary: ByteSlice
    ) -> BorrowedProtocolAction {
        switch kind {
        case .deliver:
            return .deliver(materializeDelivery(
                payload: primary,
                topic: secondary,
                selector: tertiary
            ))
        case .publish:
            let target: BorrowedProtocolPublishTarget
            switch publishTargetKind {
            case .profile:
                target = .profile(
                    eventTypeFilter: topicPresent ? secondary : nil,
                    filterKind: filterKind
                )
            case .associationRoute:
                target = .associationRoute(route: secondary, kind: routeClassification)
            }
            return .publish(BorrowedProtocolPublication(
                routingKey: routingKey!,
                target: target,
                payload: primary,
                isApplicationDelivery: applicationDelivery
            ))
        case .associationChanged:
            let route = associationRoutePresent
                ? BorrowedProtocolRouteSnapshot(slice: quaternary)
                : nil
            return .associationChanged(BorrowedIoAssociationTransition(
                delivery: materializeDelivery(
                    payload: primary,
                    topic: secondary,
                    selector: tertiary
                ),
                sourceID: sourceID,
                actorID: actorID,
                change: associationChange,
                route: route,
                routeClassification: routeClassification
            ))
        case .externalRouteActivated:
            return .externalRouteActivated(BorrowedExternalRouteTransition(
                sourceID: sourceID,
                actorID: actorID,
                route: secondary
            ))
        case .externalRouteDeactivated:
            return .externalRouteDeactivated(BorrowedExternalRouteTransition(
                sourceID: sourceID,
                actorID: actorID,
                route: secondary
            ))
        }
    }

    private borrowing func materializeDelivery(
        payload: ByteSlice,
        topic: ByteSlice,
        selector: ByteSlice
    ) -> BorrowedProtocolDelivery {
        let key: BorrowedProtocolDeliveryKey
        switch deliveryKeyKind {
        case .capability:
            key = .capability(deliveryCapability!)
        case .advertiseFilter:
            key = .advertiseFilter(selector)
        case .channel:
            key = .channel(selector)
        case .ioActor:
            key = .ioActor(deliveryIdentity)
        case .correlated:
            key = .correlated(deliveryCapability!, deliveryIdentity)
        }
        return BorrowedProtocolDelivery(
            routingKey: routingKey!,
            deliveryKey: key,
            routeClassification: routeClassification,
            topic: topicPresent ? topic : nil,
            payload: payload
        )
    }

    private static func copy<let byteCapacity: Int>(
        _ bytes: ByteSlice,
        into storage: inout InlineArray<byteCapacity, UInt8>,
        length: inout Int
    ) -> Bool {
        guard bytes.length >= 0, bytes.length <= byteCapacity else { return false }
        for index in 0..<bytes.length { storage[index] = bytes.byte(at: index) ?? 0 }
        length = bytes.length
        return true
    }

    private static func copy<let byteCapacity: Int>(
        _ snapshot: BorrowedProtocolRouteSnapshot,
        into storage: inout InlineArray<byteCapacity, UInt8>,
        length: inout Int
    ) -> Bool {
        guard snapshot.length > 0, snapshot.length <= byteCapacity else { return false }
        for index in 0..<snapshot.length { storage[index] = snapshot.byte(at: index) ?? 0 }
        length = snapshot.length
        return true
    }

    private static func slice(_ bytes: UnsafeRawBufferPointer, length: Int) -> ByteSlice {
        slice(bytes, offset: 0, length: length)
    }

    private static func slice(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        length: Int
    ) -> ByteSlice {
        ByteSlice(
            bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset),
            length: length
        )
    }
}
