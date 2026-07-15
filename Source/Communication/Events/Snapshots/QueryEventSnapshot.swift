// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `QueryEvent` suitable for concurrent event streams.
public struct QueryEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The object types used to restrict query results.
    public let objectTypes: [String]?

    /// The core types used to restrict query results.
    public let coreTypes: [String]?

    /// The encoded object filter, if one was specified.
    public let objectFilter: Data?

    /// The encoded join conditions, if any were specified.
    public let objectJoinConditions: [Data]?

    /// Creates a snapshot of a Query event.
    ///
    /// - Parameters:
    ///   - objectTypes: An optional list of object types.
    ///   - coreTypes: An optional list of core types.
    ///   - objectFilter: An optional encoded object filter.
    ///   - objectJoinConditions: An optional list of encoded join conditions.
    public init(
        objectTypes: [String]? = nil,
        coreTypes: [String]? = nil,
        objectFilter: Data? = nil,
        objectJoinConditions: [Data]? = nil
    ) {
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        self.objectFilter = objectFilter
        self.objectJoinConditions = objectJoinConditions
    }
}
