// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `CallEvent` suitable for concurrent event streams.
public struct CallEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The name of the remote operation to be invoked.
    ///
    /// This corresponds to the `typeFilter` used to route the call on the wire.
    public let operation: String

    /// The encoded operation parameters, preserving the wire format.
    public let parameters: Data?

    /// The encoded context filter, if one was specified.
    public let filter: Data?

    /// Creates a snapshot of a Call event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - operation: The name of the remote operation.
    ///   - parameters: Optional encoded operation parameters.
    ///   - filter: Optional encoded context filter.
    public init(
        sourceId: String? = nil,
        operation: String,
        parameters: Data? = nil,
        filter: Data? = nil
    ) {
        self.sourceId = sourceId
        self.operation = operation
        self.parameters = parameters
        self.filter = filter
    }
}
