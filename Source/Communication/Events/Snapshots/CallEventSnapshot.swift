// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `CallEvent` suitable for concurrent event streams.
public struct CallEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The request correlation identifier used for a Return response.
    public let correlationId: String?

    /// The name of the remote operation to be invoked.
    ///
    /// This corresponds to the `typeFilter` used to route the call on the wire.
    public let operation: String

    /// The encoded operation parameters, preserving the wire format as JSON text.
    public let parameters: String?

    /// The encoded context filter, if one was specified, as JSON text.
    public let filter: String?

    /// Creates a snapshot of a Call event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - correlationId: The correlation identifier for a Return response.
    ///   - operation: The name of the remote operation.
    ///   - parameters: Optional encoded operation parameters.
    ///   - filter: Optional encoded context filter.
    public init(
        sourceId: String? = nil,
        correlationId: String? = nil,
        operation: String,
        parameters: String? = nil,
        filter: String? = nil
    ) {
        self.sourceId = sourceId
        self.correlationId = correlationId
        self.operation = operation
        self.parameters = parameters
        self.filter = filter
    }
}

extension CallEventSnapshot {

    /// Decodes a Call snapshot from a parsed MQTT message.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard let operation = parsedMQTTMessage.eventTypeFilter else {
            return nil
        }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            correlationId: parsedMQTTMessage.correlationId,
            operation: operation,
            parameters: WirePayloadExtractor.nestedPayload(from: parsedMQTTMessage.payload, key: "parameters"),
            filter: WirePayloadExtractor.nestedObjectPayload(from: parsedMQTTMessage.payload, key: "filter")
        )
    }
}
