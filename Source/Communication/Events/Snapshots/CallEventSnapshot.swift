// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `CallEvent` suitable for concurrent event streams.
public struct CallEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The name of the remote operation to be invoked.
    public let operation: String

    /// The encoded operation parameters, preserving the wire format.
    public let parameters: Data?

    /// The encoded context filter, if one was specified.
    public let filter: Data?

    /// Creates a snapshot of a Call event.
    ///
    /// - Parameters:
    ///   - operation: The name of the remote operation.
    ///   - parameters: Optional encoded operation parameters.
    ///   - filter: Optional encoded context filter.
    public init(
        operation: String,
        parameters: Data? = nil,
        filter: Data? = nil
    ) {
        self.operation = operation
        self.parameters = parameters
        self.filter = filter
    }
}
