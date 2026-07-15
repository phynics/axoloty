// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `QueryEvent` suitable for concurrent event streams.
public struct QueryEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The object types used to restrict query results.
    public let objectTypes: [String]?

    /// The core types used to restrict query results.
    public let coreTypes: [CoreType]?

    /// The encoded object filter, if one was specified.
    public let objectFilter: Data?

    /// The encoded join conditions, if any were specified.
    public let objectJoinConditions: [Data]?

    /// The encoded single join condition, if one was specified.
    ///
    /// Legacy `QueryEventData` stores either a single condition or an array of
    /// conditions under the same coding key; this property preserves the single
    /// condition case without referencing the legacy type.
    public let objectJoinCondition: Data?

    /// Creates a snapshot of a Query event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - objectTypes: An optional list of object types.
    ///   - coreTypes: An optional list of core types.
    ///   - objectFilter: An optional encoded object filter.
    ///   - objectJoinConditions: An optional list of encoded join conditions.
    ///   - objectJoinCondition: An optional encoded single join condition.
    public init(
        sourceId: String? = nil,
        objectTypes: [String]? = nil,
        coreTypes: [CoreType]? = nil,
        objectFilter: Data? = nil,
        objectJoinConditions: [Data]? = nil,
        objectJoinCondition: Data? = nil
    ) {
        self.sourceId = sourceId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        self.objectFilter = objectFilter
        self.objectJoinConditions = objectJoinConditions
        self.objectJoinCondition = objectJoinCondition
    }
}
