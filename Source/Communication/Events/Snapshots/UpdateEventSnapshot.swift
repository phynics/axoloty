// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of an `UpdateEvent` suitable for concurrent event streams.
public struct UpdateEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The object whose properties are to be updated.
    public let object: CoatyObjectSnapshot

    /// Creates a snapshot of an Update event.
    ///
    /// - Parameter object: The object with properties to be updated.
    public init(object: CoatyObjectSnapshot) {
        self.object = object
    }
}
