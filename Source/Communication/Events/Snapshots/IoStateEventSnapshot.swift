// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A value-typed snapshot of the local association state of an IO point.
public struct IoStateEventSnapshot: Codable, Equatable, Sendable {
    /// The IO point identifier.
    public let ioPointId: String
    /// Whether the point currently has one or more associations.
    public let hasAssociations: Bool
    /// The negotiated source update rate, when applicable.
    public let updateRate: Int?

    /// Creates an IO state snapshot.
    public init(ioPointId: String, hasAssociations: Bool, updateRate: Int? = nil) {
        self.ioPointId = ioPointId
        self.hasAssociations = hasAssociations
        self.updateRate = updateRate
    }
}
