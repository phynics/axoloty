// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `DiscoverEvent` suitable for concurrent event streams.
public struct DiscoverEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

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
        externalId: String? = nil,
        objectId: String? = nil,
        objectTypes: [String]? = nil,
        coreTypes: [CoreType]? = nil
    ) {
        self.sourceId = sourceId
        self.externalId = externalId
        self.objectId = objectId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
    }
}
