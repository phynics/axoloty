// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot for a correlated response event.
public struct ResponseEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {
    /// The response event kind as it appears on the wire.
    public let eventType: String
    /// The response source identifier.
    public let sourceId: String?
    /// The correlation identifier.
    public let correlationId: String?
    /// The encoded response payload.
    public let payload: Data

    /// Creates a response snapshot.
    public init(eventType: String, sourceId: String?, correlationId: String?, payload: Data) {
        self.eventType = eventType
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.payload = payload
    }
}
