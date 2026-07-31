// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Processes Advertise and Deadvertise events against an
/// ``ObjectCatalogue``, applying the configured filter and producing
/// ``ObjectCatalogueMutation`` values.
///
/// The reducer is pure: it does not perform I/O or maintain mutable state.
/// Each call returns the updated catalogue and the mutation that describes
/// the change.
public struct ObjectCatalogueReducer: Sendable {
    /// The filter applied to advertised objects before insertion.
    public let filter: ObjectCatalogueFilter

    /// Creates a reducer with the given filter.
    public init(filter: ObjectCatalogueFilter = .none) {
        self.filter = filter
    }

    /// Processes an Advertise event.
    ///
    /// If the object does not match the filter, the catalogue is unchanged
    /// and `nil` is returned for the mutation (no output should be produced).
    /// If the object matches and is already in the catalogue with identical
    /// contents, `.unchanged` is returned. If the contents differ, `.updated`
    /// is returned. If the object is new, `.inserted` is returned.
    ///
    /// - Parameters:
    ///   - object: The advertised object.
    ///   - catalogue: The current catalogue state.
    /// - Returns: The updated catalogue and the mutation (or `nil` if
    ///   filtered out).
    public func reduceAdvertise(
        _ object: InspectorObject,
        into catalogue: ObjectCatalogue
    ) -> (ObjectCatalogue, ObjectCatalogueMutation?) {
        guard filter.matches(object) else {
            return (catalogue, nil)
        }

        if let existing = catalogue.objectsById[object.objectId] {
            if existing == object {
                return (catalogue, .unchanged(object))
            }
            var updated = catalogue
            updated.objectsById[object.objectId] = object
            return (updated, .updated(previous: existing, current: object))
        }

        var inserted = catalogue
        inserted.objectsById[object.objectId] = object
        return (inserted, .inserted(object))
    }

    /// Processes a Deadvertise event containing one or more object IDs.
    ///
    /// Each ID is looked up in the catalogue. Known objects are removed and
    /// produce `.removed`. Unknown IDs produce `.removalOfUnknownObject` and
    /// are nonfatal. Filtering does not apply to Deadvertise — only objects
    /// that previously passed the filter and entered the catalogue are
    /// present to be removed.
    ///
    /// - Parameters:
    ///   - objectIds: The object IDs to remove.
    ///   - catalogue: The current catalogue state.
    /// - Returns: An array of (catalogue, mutation) pairs, one per object ID.
    public func reduceDeadvertise(
        _ objectIds: [String],
        into catalogue: ObjectCatalogue
    ) -> [(ObjectCatalogue, ObjectCatalogueMutation)] {
        var current = catalogue
        var results: [(ObjectCatalogue, ObjectCatalogueMutation)] = []

        for objectId in objectIds {
            if let existing = current.objectsById[objectId] {
                current.objectsById.removeValue(forKey: objectId)
                results.append((current, .removed(existing)))
            } else {
                results.append((current, .removalOfUnknownObject(objectId: objectId)))
            }
        }

        return results
    }
}
