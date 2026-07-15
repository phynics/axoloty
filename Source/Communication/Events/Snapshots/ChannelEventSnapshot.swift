// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `ChannelEvent` suitable for concurrent event streams.
public struct ChannelEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

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

    /// Application-specific private data associated with the broadcast, if any.
    public let privateData: Data?

    /// Creates a snapshot of a Channel event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - object: An optional single object to be broadcast.
    ///   - objects: An optional collection of objects to be broadcast.
    ///   - channelId: The channel identifier.
    ///   - eventTypeFilter: The optional event type filter used for routing.
    ///   - privateData: Optional application-specific private data.
    public init(
        sourceId: String? = nil,
        object: CoatyObjectSnapshot? = nil,
        objects: [CoatyObjectSnapshot]? = nil,
        channelId: String,
        eventTypeFilter: String? = nil,
        privateData: Data? = nil
    ) {
        self.sourceId = sourceId
        self.object = object
        self.objects = objects
        self.channelId = channelId
        self.eventTypeFilter = eventTypeFilter
        self.privateData = privateData
    }
}
