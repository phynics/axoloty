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
    /// The response payload as raw JSON text.
    public let payload: String

    /// Creates a response snapshot.
    public init(eventType: String, sourceId: String?, correlationId: String?, payload: String) {
        self.eventType = eventType
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.payload = payload
    }

    /// Decodes the raw JSON payload into a typed `Decodable` value.
    ///
    /// - Parameter type: The type to decode the payload as.
    /// - Returns: The decoded value, or `nil` if decoding fails.
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }
}
