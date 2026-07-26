// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

/// A value-typed snapshot of a `DiscoverEvent` suitable for concurrent event streams.
public struct DiscoverEventSnapshot: Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The request correlation identifier used for a Resolve response.
    public let correlationId: String?

    /// The external ID of the object(s) to be discovered.
    public let externalId: String?

    /// The object UUID of the object to be discovered.
    public let objectId: String?

    /// The object types used to restrict discovery results.
    public let objectTypes: [String]?

    /// The core types used to restrict discovery results.
    public let coreTypes: [CoreType]?

    /// Creates a snapshot of a Discover event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - externalId: An optional external ID to discover.
    ///   - objectId: An optional object identifier to discover.
    ///   - objectTypes: An optional list of object types.
    ///   - coreTypes: An optional list of core types.
    public init(
        sourceId: String? = nil,
        correlationId: String? = nil,
        externalId: String? = nil,
        objectId: String? = nil,
        objectTypes: [String]? = nil,
        coreTypes: [CoreType]? = nil
    ) {
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.externalId = externalId
        self.objectId = objectId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
    }
}

extension DiscoverEventSnapshot {

    /// Decodes a Discover snapshot from a parsed MQTT message via a single
    /// ``WireReader`` pass.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        var payload = parsedMQTTMessage.payload
        guard let decoded = payload.withUTF8({ buf -> (String?, String?, [String]?, [CoreType]?)? in
            guard let base = buf.baseAddress else { return nil }
            let reader = WireReader(bytes: base, length: buf.count)
            guard let wire = try? DiscoverWireData(from: reader) else { return nil }
            let externalId = wire.externalId?.asString()
            let objectId = wire.objectId?.asString()
            let objectTypes = wire.objectTypes.flatMap { WirePayloadExtractor.decodeJSON([String].self, from: $0) }
            let coreTypes = wire.coreTypes.flatMap { WirePayloadExtractor.decodeJSON([CoreType].self, from: $0) }
            return (externalId, objectId, objectTypes, coreTypes)
        }) else { return nil }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            correlationId: parsedMQTTMessage.correlationId,
            externalId: decoded.0,
            objectId: decoded.1,
            objectTypes: decoded.2,
            coreTypes: decoded.3
        )
    }
}
