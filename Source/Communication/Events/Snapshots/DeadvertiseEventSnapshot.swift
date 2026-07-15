// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `DeadvertiseEvent` suitable for concurrent event streams.
public struct DeadvertiseEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The object identifiers of the objects to be deadvertised.
    public let objectIds: [String]

    /// Creates a snapshot of a Deadvertise event.
    ///
    /// - Parameter objectIds: The object identifiers to be deadvertised.
    public init(objectIds: [String]) {
        self.objectIds = objectIds
    }
}
