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
    /// The filter used to determine advertised object catalogue membership.
    public let filter: ObjectCatalogueFilter

    /// Creates a reducer with the given filter.
    public init(filter: ObjectCatalogueFilter = .none) {
        self.filter = filter
    }

    /// Processes an Advertise event.
    ///
    /// If a new object does not match the filter, the catalogue is unchanged
    /// and `nil` is returned for the mutation. If an existing object no longer
    /// matches the filter, it is removed and `.removed` is returned. If the
    /// object matches and is already in the catalogue with identical contents,
    /// `.unchanged` is returned. If the contents differ, `.updated` is
    /// returned. If the object is new, `.inserted` is returned.
    ///
    /// - Parameters:
    ///   - object: The advertised object.
    ///   - catalogue: The current catalogue state.
    /// - Returns: The updated catalogue and the mutation. A new filtered-out
    ///   object produces `nil`; a previously catalogued object that becomes
    ///   filtered out produces `.removed`.
    public func reduceAdvertise(
        _ object: InspectorObject,
        into catalogue: ObjectCatalogue
    ) -> (ObjectCatalogue, ObjectCatalogueMutation?) {
        if !filter.matches(object) {
            guard let existing = catalogue.objectsById[object.objectId] else {
                return (catalogue, nil)
            }

            var removed = catalogue
            removed.objectsById.removeValue(forKey: object.objectId)
            return (removed, .removed(existing))
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
