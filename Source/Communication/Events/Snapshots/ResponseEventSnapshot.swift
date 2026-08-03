// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot for a correlated response event.
public struct ResponseEventSnapshot: Codable, Equatable, Sendable {
    /// The response event kind as it appears on the wire.
    public let eventType: String
    /// The response source identifier.
    public let sourceId: String?
    /// The correlation identifier.
    public let correlationId: String?
    /// The response payload as raw JSON text.
    public let payload: String
    /// A hydrated object carried by Resolve or Complete, when present.
    public let object: CoatyObjectSnapshot?

    /// Creates a response snapshot.
    public init(eventType: String, sourceId: String?, correlationId: String?, payload: String, object: CoatyObjectSnapshot? = nil) {
        self.eventType = eventType
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.payload = payload
        self.object = object
    }

    /// Decodes the raw JSON payload into a typed `Decodable` value.
    ///
    /// - Parameter type: The type to decode the payload as.
    /// - Returns: The decoded value, or `nil` if decoding fails.
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }
}
