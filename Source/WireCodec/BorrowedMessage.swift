// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A borrowed view of an incoming MQTT PUBLISH, zero-allocation.
///
/// Replaces the `RawMQTTMessage` (topic String + payload [UInt8]) and
/// `ParsedMQTTMessage` (topic fields as Strings + payload String) with a
/// single borrowed view that holds raw pointers into the receive buffer.
///
/// The routing decision is made from `eventType` (a 3-byte comparison via
/// `TopicView`) without ever constructing a `CommunicationTopic` class or
/// calling `String.components(separatedBy:)`. The payload is accessed via
/// `WireReader` for typed field decode without a JSON value tree.
///
/// - Important: The caller must ensure both the topic and payload buffers
///   outlive the `BorrowedMessage`. This type is intentionally not `Sendable`;
///   it is designed for synchronous dispatch in the routing hot path.
public struct BorrowedMessage {
    public let topic: TopicView
    public let payload: ByteSlice
    public let eventType: WireEventType?

    /// Creates a borrowed message from raw topic and payload bytes.
    public init(
        topicBytes: UnsafePointer<UInt8>,
        topicLength: Int,
        payloadBytes: UnsafePointer<UInt8>,
        payloadLength: Int
    ) {
        self.topic = TopicView(topicBytes: topicBytes, length: topicLength)
        self.payload = ByteSlice(bytes: payloadBytes, length: payloadLength)
        self.eventType = self.topic.eventType
    }

    /// Creates a WireReader for the payload, enabling typed field access
    /// without allocating a String or intermediate JSON tree.
    public func reader() -> WireReader {
        payload.withBytes { ptr, len in
            WireReader(
                bytes: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                length: len
            )
        }
    }

    /// Whether this message is a raw (non-Coaty) topic.
    public var isRawTopic: Bool {
        topic.isRawTopic
    }
}
