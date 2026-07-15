// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of an `AdvertiseEvent` suitable for concurrent event streams.
public struct AdvertiseEventSnapshot: EventSnapshot, Codable, Equatable, Sendable {

    /// The object being advertised.
    public let object: CoatyObjectSnapshot

    /// Application-specific private data associated with the advertisement, if any.
    public let privateData: Data?

    /// Creates a snapshot of an Advertise event.
    ///
    /// - Parameters:
    ///   - object: The object being advertised.
    ///   - privateData: Optional application-specific private data.
    public init(
        object: CoatyObjectSnapshot,
        privateData: Data? = nil
    ) {
        self.object = object
        self.privateData = privateData
    }
}
