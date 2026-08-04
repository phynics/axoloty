// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire

/// A value-typed snapshot of a `QueryEvent` suitable for concurrent event streams.
public struct QueryEventSnapshot: Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The request correlation identifier used for a Retrieve response.
    public let correlationId: String?

    /// The object types used to restrict query results.
    public let objectTypes: [String]?

    /// The core types used to restrict query results.
    public let coreTypes: [CoreType]?

    /// The encoded object filter, if one was specified, as raw JSON text.
    public let objectFilter: String?

    /// The encoded join conditions, if any were specified, as raw JSON text.
    public let objectJoinConditions: [String]?

    /// The encoded single join condition, if one was specified, as raw JSON
    /// text.
    ///
    /// Legacy `QueryEventData` stores either a single condition or an array of
    /// conditions under the same coding key; this property preserves the single
    /// condition case without referencing the legacy type.
    public let objectJoinCondition: String?

    /// Creates a snapshot of a Query event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - correlationId: The correlation identifier for a Retrieve response.
    ///   - objectTypes: An optional list of object types.
    ///   - coreTypes: An optional list of core types.
    ///   - objectFilter: An optional encoded object filter as raw JSON text.
    ///   - objectJoinConditions: An optional list of encoded join conditions as raw JSON text.
    ///   - objectJoinCondition: An optional encoded single join condition as raw JSON text.
    public init(
        sourceId: String? = nil,
        correlationId: String? = nil,
        objectTypes: [String]? = nil,
        coreTypes: [CoreType]? = nil,
        objectFilter: String? = nil,
        objectJoinConditions: [String]? = nil,
        objectJoinCondition: String? = nil
    ) {
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        self.objectFilter = objectFilter
        self.objectJoinConditions = objectJoinConditions
        self.objectJoinCondition = objectJoinCondition
    }
}

extension QueryEventSnapshot {

    /// Decodes a Query snapshot from a parsed MQTT message via a single
    /// ``WireReader`` pass.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard case .query(let wire) = parsedMQTTMessage.event else { return nil }
        let join = wire.objectJoinConditions.flatMap { String(bytes: $0, encoding: .utf8) }
        let joinConditions = wire.objectJoinConditions.flatMap(WirePayloadExtractor.arrayElements)
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            correlationId: parsedMQTTMessage.correlationId,
            objectTypes: wire.objectTypes.flatMap { try? JSONDecoder().decode([String].self, from: Data($0)) },
            coreTypes: wire.coreTypes.flatMap { try? JSONDecoder().decode([CoreType].self, from: Data($0)) },
            objectFilter: wire.objectFilter.flatMap { String(bytes: $0, encoding: .utf8) },
            objectJoinConditions: joinConditions,
            objectJoinCondition: join?.first == "{" ? join : nil
        )
    }
}
