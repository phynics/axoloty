// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A raw MQTT transport message received from the broker.
///
/// This value type wraps the topic and payload of an incoming MQTT
/// ``PUBLISH`` packet before any higher-level Coaty parsing is applied. It
/// conforms to ``Sendable`` so it can safely cross the ``Broadcast`` boundary
/// from the MQTT client to async consumers.
public struct RawMQTTMessage: Sendable, Hashable {

    /// The MQTT topic on which the message was published.
    public let topic: String

    /// The raw message payload as a byte array.
    public let payload: [UInt8]

    /// Creates a new raw MQTT message.
    ///
    /// - Parameters:
    ///   - topic: the MQTT topic name.
    ///   - payload: the raw payload bytes.
    public init(topic: String, payload: [UInt8]) {
        self.topic = topic
        self.payload = payload
    }
}
