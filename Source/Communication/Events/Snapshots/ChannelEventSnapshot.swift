// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of a `ChannelEvent` suitable for concurrent event streams.
public struct ChannelEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// A single object broadcast on the channel.
    public let object: CoatyObjectSnapshot?

    /// Multiple objects broadcast on the channel.
    public let objects: [CoatyObjectSnapshot]?

    /// The channel identifier used for routing the broadcast.
    public let channelId: String

    /// Application-specific private data associated with the broadcast, if any.
    public let privateData: Data?

    /// Creates a snapshot of a Channel event.
    ///
    /// - Parameters:
    ///   - object: An optional single object to be broadcast.
    ///   - objects: An optional collection of objects to be broadcast.
    ///   - channelId: The channel identifier.
    ///   - privateData: Optional application-specific private data.
    public init(
        object: CoatyObjectSnapshot? = nil,
        objects: [CoatyObjectSnapshot]? = nil,
        channelId: String,
        privateData: Data? = nil
    ) {
        self.object = object
        self.objects = objects
        self.channelId = channelId
        self.privateData = privateData
    }
}
