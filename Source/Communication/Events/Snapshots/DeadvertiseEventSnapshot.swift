// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

/// A value-typed snapshot of a `DeadvertiseEvent` suitable for concurrent event streams.
public struct DeadvertiseEventSnapshot: Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The object identifiers of the objects to be deadvertised.
    public let objectIds: [String]

    /// Creates a snapshot of a Deadvertise event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - objectIds: The object identifiers to be deadvertised.
    public init(sourceId: String? = nil, objectIds: [String]) {
        self.sourceId = sourceId
        self.objectIds = objectIds
    }
}

extension DeadvertiseEventSnapshot {

    /// Decodes a Deadvertise snapshot from a parsed MQTT message via a single
    /// ``WireReader`` pass, decoding the `objectIds` array from the borrowed
    /// bytes (preserving the original UUID strings without normalizing them
    /// through ``UUID16``).
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        var payload = parsedMQTTMessage.payload
        guard let objectIds = payload.withUTF8({ buf -> [String]? in
            guard let base = buf.baseAddress else { return nil }
            let reader = WireReader(bytes: base, length: buf.count)
            guard let wire = try? DeadvertiseWireData(from: reader) else { return nil }
            return WirePayloadExtractor.decodeJSON([String].self, from: wire.objectIds)
        }) else { return nil }
        self.init(sourceId: parsedMQTTMessage.sourceId, objectIds: objectIds)
    }
}
