// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A combined filter applied to advertised objects before catalogue
/// mutation and output.
///
/// All specified fields are ANDed: an object must match every non-nil
/// field to pass the filter.
public struct ObjectCatalogueFilter: Equatable, Sendable {
    /// Filter by core type name, if specified.
    public let coreType: String?
    /// Filter by full object type, if specified.
    public let objectType: String?
    /// Filter by object UUID, if specified.
    public let objectId: String?
    /// Filter by source (advertiser) UUID, if specified.
    public let sourceId: String?

    /// Creates a filter. All fields are optional; `nil` means no constraint
    /// on that field.
    public init(
        coreType: String? = nil,
        objectType: String? = nil,
        objectId: String? = nil,
        sourceId: String? = nil
    ) {
        self.coreType = coreType
        self.objectType = objectType
        self.objectId = objectId
        self.sourceId = sourceId
    }

    /// A filter that matches every object.
    public static let none = ObjectCatalogueFilter()

    /// Returns `true` when `object` satisfies all specified fields.
    public func matches(_ object: InspectorObject) -> Bool {
        if let coreType, object.coreType != coreType { return false }
        if let objectType, object.objectType != objectType { return false }
        if let objectId, object.objectId != objectId { return false }
        if let sourceId, object.sourceId != sourceId { return false }
        return true
    }
}
