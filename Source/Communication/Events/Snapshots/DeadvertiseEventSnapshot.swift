// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `DeadvertiseEvent` suitable for concurrent event streams.
public struct DeadvertiseEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

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
