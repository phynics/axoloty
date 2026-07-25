// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A borrowed view of an incoming MQTT PUBLISH, zero-allocation.
///
/// Replaces the `RawMQTTMessage` (topic String + payload [UInt8]) and
/// `ParsedMQTTMessage` (topic fields as Strings + payload String) with a
/// single borrowed view that holds raw pointers into the receive buffer.
///
/// The routing decision is made from `eventType` (a 3-byte comparison via
/// `TopicView`) without ever allocating a `String` via
/// `String.components(separatedBy:)`. The payload is accessed via
/// `WireReader` for typed field decode without a JSON value tree.
///
/// - Important: The caller must ensure both the topic and payload buffers
///   outlive the `BorrowedMessage`. This type is intentionally not `Sendable`;
///   it is designed for synchronous dispatch in the routing hot path.
public struct BorrowedMessage {
    /// The parsed topic view borrowing the topic bytes.
    public let topic: TopicView
    /// The message payload as a borrowed byte slice.
    public let payload: ByteSlice
    /// The Coaty event type parsed from the topic, or nil for raw topics.
    public let eventType: WireEventType?

    /// Creates a borrowed message from raw topic and payload bytes.
    ///
    /// - Important: This initializer performs **no size validation**. It is
    ///   intended for callers that have already bounded the input (e.g. a
    ///   fixed-size receive buffer). For untrusted input, use
    ///   ``validated(topicBytes:topicLength:payloadBytes:payloadLength:)``,
    ///   which enforces ``WireBufferConfig.maxTopicLength`` and
    ///   ``WireBufferConfig.maxPayloadSize`` and throws a structured
    ///   ``WireDecodeError`` on overflow.
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

    /// Creates a borrowed message from raw topic and payload bytes, enforcing
    /// the bounded-cost limits in ``WireBufferConfig``.
    ///
    /// Use this factory for untrusted input (e.g. an MQTT PUBLISH from a
    /// peer). It checks the topic and payload lengths against
    /// ``WireBufferConfig.maxTopicLength`` and
    /// ``WireBufferConfig.maxPayloadSize`` before constructing the view, so an
    /// oversized message is rejected with a structured ``WireDecodeError``
    /// rather than driving unbounded allocation or processing on a
    /// memory-constrained device.
    ///
    /// - Parameters:
    ///   - topicBytes: A pointer to the UTF-8 topic bytes.
    ///   - topicLength: The number of valid topic bytes.
    ///   - payloadBytes: A pointer to the payload bytes.
    ///   - payloadLength: The number of valid payload bytes.
    /// - Throws: ``WireDecodeError`` with reason
    ///   ``.topicExceedsLimit`` if `topicLength` exceeds
    ///   ``WireBufferConfig.maxTopicLength``, or ``.payloadExceedsLimit`` if
    ///   `payloadLength` exceeds ``WireBufferConfig.maxPayloadSize``.
    public static func validated(
        topicBytes: UnsafePointer<UInt8>,
        topicLength: Int,
        payloadBytes: UnsafePointer<UInt8>,
        payloadLength: Int
    ) throws -> BorrowedMessage {
        if topicLength > WireBufferConfig.maxTopicLength {
            throw WireDecodeError(.topicExceedsLimit, byteOffset: topicLength)
        }
        if payloadLength > WireBufferConfig.maxPayloadSize {
            throw WireDecodeError(.payloadExceedsLimit, byteOffset: payloadLength)
        }
        return BorrowedMessage(
            topicBytes: topicBytes, topicLength: topicLength,
            payloadBytes: payloadBytes, payloadLength: payloadLength
        )
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
