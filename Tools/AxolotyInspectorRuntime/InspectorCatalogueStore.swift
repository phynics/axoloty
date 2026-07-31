// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation

/// A concurrency-safe, inspector-owned catalogue store.
///
/// The store is actor-isolated so it can be safely queried from any
/// concurrency domain. Passive MQTT observation updates it; MCP tool
/// handlers read from it.
public actor InspectorCatalogueStore {
    private var objectsById: [String: InspectorObject] = [:]
    private let observedSince: String
    private let namespace: String

    /// Creates a store.
    public init(observedSince: String, namespace: String) {
        self.observedSince = observedSince
        self.namespace = namespace
    }

    /// Applies an advertised object to the store (insert or update).
    public func apply(_ object: InspectorObject) {
        objectsById[object.objectId] = object
    }

    /// Removes objects by their IDs (from Deadvertise events).
    public func remove(objectIds: [String]) {
        for id in objectIds {
            objectsById.removeValue(forKey: id)
        }
    }

    /// Returns a filtered snapshot of the catalogue.
    public func snapshot(filter: ObjectCatalogueFilter) -> InspectorCatalogueSnapshot {
        let objects = objectsById.values.filter { filter.matches($0) }.sorted { $0.objectId < $1.objectId }
        return InspectorCatalogueSnapshot(
            complete: false,
            observedSince: observedSince,
            namespace: namespace,
            objects: objects
        )
    }

    /// Returns a specific object by ID, if catalogued.
    public func object(id: String) -> InspectorObject? {
        objectsById[id]
    }

    /// The number of catalogued objects.
    public var count: Int {
        objectsById.count
    }
}
