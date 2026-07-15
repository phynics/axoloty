// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of an `AdvertiseEvent` suitable for concurrent event streams.
public struct AdvertiseEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The identifier of the event source, as derived from the incoming topic.
    public let sourceId: String?

    /// The event type filter used to route the advertisement, if any.
    ///
    /// This corresponds to the `typeFilter` set on a legacy `AdvertiseEvent`
    /// and is either a core type name or an object type prefixed with the
    /// event type filter separator.
    public let eventTypeFilter: String?

    /// The object being advertised.
    public let object: CoatyObjectSnapshot

    /// Application-specific private data associated with the advertisement, if any.
    public let privateData: Data?

    /// Creates a snapshot of an Advertise event.
    ///
    /// - Parameters:
    ///   - sourceId: The identifier of the event source.
    ///   - eventTypeFilter: The optional event type filter used for routing.
    ///   - object: The object being advertised.
    ///   - privateData: Optional application-specific private data.
    public init(
        sourceId: String? = nil,
        eventTypeFilter: String? = nil,
        object: CoatyObjectSnapshot,
        privateData: Data? = nil
    ) {
        self.sourceId = sourceId
        self.eventTypeFilter = eventTypeFilter
        self.object = object
        self.privateData = privateData
    }
}
