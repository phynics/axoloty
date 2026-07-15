// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `DiscoverEvent` suitable for concurrent event streams.
public struct DiscoverEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The external ID of the object(s) to be discovered.
    public let externalId: String?

    /// The object UUID of the object to be discovered.
    public let objectId: String?

    /// The object types used to restrict discovery results.
    public let objectTypes: [String]?

    /// The core types used to restrict discovery results.
    public let coreTypes: [String]?

    /// Creates a snapshot of a Discover event.
    ///
    /// - Parameters:
    ///   - externalId: An optional external ID to discover.
    ///   - objectId: An optional object identifier to discover.
    ///   - objectTypes: An optional list of object types.
    ///   - coreTypes: An optional list of core types.
    public init(
        externalId: String? = nil,
        objectId: String? = nil,
        objectTypes: [String]? = nil,
        coreTypes: [String]? = nil
    ) {
        self.externalId = externalId
        self.objectId = objectId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
    }
}
