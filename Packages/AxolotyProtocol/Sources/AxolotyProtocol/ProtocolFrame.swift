// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A profile routing key derived from a validated Coaty topic.
public struct ProtocolRoutingKey: Sendable, Equatable, Hashable {
    /// The closed-profile capability carried by the frame.
    public let capability: ProtocolCapability
    /// The source identifier from topic level four.
    public let sourceID: UUID16
    /// The correlation identifier, present only for request/response events.
    public let correlationID: UUID16?

    /// Creates a validated routing key.
    ///
    /// - Throws: ``ProtocolError`` when correlation presence does not match
    ///   the event family.
    public init(
        capability: ProtocolCapability,
        sourceID: UUID16,
        correlationID: UUID16? = nil
    ) throws(ProtocolError) {
        if capability.isOneWay && correlationID != nil {
            throw ProtocolError(.invalidCorrelation)
        }
        if !capability.isOneWay && correlationID == nil {
            throw ProtocolError(.invalidCorrelation)
        }
        self.capability = capability
        self.sourceID = sourceID
        self.correlationID = correlationID
    }
}

/// An owned, sendable protocol frame.
public struct ProtocolFrame: Sendable, Equatable {
    /// The validated routing key.
    public let routingKey: ProtocolRoutingKey
    /// The copied payload bytes.
    public let payload: [UInt8]

    /// Creates an owned frame by copying the supplied payload.
    public init(routingKey: ProtocolRoutingKey, payload: [UInt8]) {
        self.routingKey = routingKey
        self.payload = payload
    }
}

/// A synchronous, borrowed protocol frame view.
///
/// This type intentionally is not `Sendable`. It is valid only while the
/// source topic and payload buffers remain pinned. Call ``owned()`` before an
/// asynchronous or isolation-domain boundary.
public struct BorrowedProtocolFrame {
    /// The validated routing key.
    public let routingKey: ProtocolRoutingKey
    /// The borrowed payload view.
    public let payload: ByteSlice

    /// Parses a validated Coaty topic and borrows its payload.
    ///
    /// - Throws: ``ProtocolError`` for malformed topics, unsupported families,
    ///   invalid UUIDs, or invalid correlation layout.
    public init(topic: TopicView, payload: ByteSlice) throws(ProtocolError) {
        do {
            try topic.validate()
        } catch {
            throw ProtocolError(.malformedFrame)
        }
        guard let wireEventType = topic.eventType,
              let capability = ProtocolCapability(wireEventType: wireEventType),
              let sourceSlice = topic.sourceIdLevel,
              let sourceID = UUID16(parsing: sourceSlice) else {
            throw ProtocolError(.unsupportedCapability)
        }
        let correlationID: UUID16?
        if let correlationSlice = topic.correlationIdLevel {
            guard let parsed = UUID16(parsing: correlationSlice) else {
                throw ProtocolError(.invalidCorrelation)
            }
            correlationID = parsed
        } else {
            correlationID = nil
        }
        self.routingKey = try ProtocolRoutingKey(
            capability: capability,
            sourceID: sourceID,
            correlationID: correlationID
        )
        self.payload = payload
    }

    /// Copies the borrowed payload into an owned, sendable frame.
    public func owned() -> ProtocolFrame {
        let copied = payload.withBytes { pointer, length in
            Array(UnsafeBufferPointer(
                start: pointer.assumingMemoryBound(to: UInt8.self),
                count: length
            ))
        }
        return ProtocolFrame(routingKey: routingKey, payload: copied)
    }
}
