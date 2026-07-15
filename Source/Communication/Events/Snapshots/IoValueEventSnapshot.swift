// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a raw incoming IO value message.
public struct IoValueEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {
    /// The complete MQTT route carrying the IO value.
    public let topic: String
    /// The raw value payload.
    public let payload: [UInt8]

    /// Creates an IO value snapshot.
    public init(topic: String, payload: [UInt8]) {
        self.topic = topic
        self.payload = payload
    }
}
