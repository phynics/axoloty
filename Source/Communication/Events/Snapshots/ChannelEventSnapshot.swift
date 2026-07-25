// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `ChannelEvent` suitable for concurrent event streams.
public struct ChannelEventSnapshot: Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// A single object broadcast on the channel.
    public let object: CoatyObjectSnapshot?

    /// Multiple objects broadcast on the channel.
    public let objects: [CoatyObjectSnapshot]?

    /// The channel identifier used for routing the broadcast.
    public let channelId: String

    /// The event type filter used to route the channel broadcast.
    ///
    /// This corresponds to the `typeFilter` set on a legacy `ChannelEvent`
    /// and matches the channel identifier.
    public let eventTypeFilter: String?

    /// Application-specific private data associated with the broadcast, as
    /// raw JSON text, if any.
    public let privateData: String?

    /// Creates a snapshot of a Channel event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - object: An optional single object to be broadcast.
    ///   - objects: An optional collection of objects to be broadcast.
    ///   - channelId: The channel identifier.
    ///   - eventTypeFilter: The optional event type filter used for routing.
    ///   - privateData: Optional application-specific private data as raw JSON text.
    public init(
        sourceId: String? = nil,
        object: CoatyObjectSnapshot? = nil,
        objects: [CoatyObjectSnapshot]? = nil,
        channelId: String,
        eventTypeFilter: String? = nil,
        privateData: String? = nil
    ) {
        self.sourceId = sourceId
        self.object = object
        self.objects = objects
        self.channelId = channelId
        self.eventTypeFilter = eventTypeFilter
        self.privateData = privateData
    }
}

extension ChannelEventSnapshot {

    /// Decodes a Channel snapshot from a parsed MQTT message via a single
    /// ``WireReader`` pass, decoding the object(s) ``CoatyObjectSnapshot``
    /// from the borrowed bytes.
    init?(parsedMQTTMessage: ParsedMQTTMessage) {
        guard let channelId = parsedMQTTMessage.eventTypeFilter else { return nil }
        var payload = parsedMQTTMessage.payload
        guard let decoded = payload.withUTF8({ buf -> (CoatyObjectSnapshot?, [CoatyObjectSnapshot]?, String?)? in
            guard let base = buf.baseAddress else { return nil }
            let reader = WireReader(bytes: base, length: buf.count)
            guard let wire = try? ChannelWireData(from: reader) else { return nil }
            let object: CoatyObjectSnapshot?
            if let objSlice = wire.object {
                let objectJSON = objSlice.asString()
                let coaty: CoatyObjectSnapshot? = try? PayloadCoder.decode(objectJSON)
                object = coaty?.withPayload(objectJSON)
            } else {
                object = nil
            }
            let objects: [CoatyObjectSnapshot]?
            if let objsSlice = wire.objects {
                let objsJSON = objsSlice.asString()
                let decoded: [CoatyObjectSnapshot]? = try? PayloadCoder.decode(objsJSON)
                objects = decoded
            } else {
                objects = nil
            }
            return (object, objects, wire.privateData?.asString())
        }) else { return nil }
        self.init(
            sourceId: parsedMQTTMessage.sourceId,
            object: decoded.0,
            objects: decoded.1,
            channelId: channelId,
            eventTypeFilter: parsedMQTTMessage.eventTypeFilter,
            privateData: decoded.2
        )
    }
}
