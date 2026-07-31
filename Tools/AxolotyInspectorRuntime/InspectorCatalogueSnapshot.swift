// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation

/// A point-in-time snapshot of the inspector catalogue.
public struct InspectorCatalogueSnapshot: Codable, Sendable, Equatable {
    /// Always `false` — passive MQTT observation cannot prove all live
    /// objects have advertised since the observer connected.
    public let complete: Bool
    /// ISO 8601 timestamp when observation began.
    public let observedSince: String
    /// The Coaty namespace being observed.
    public let namespace: String
    /// The catalogued objects matching the filter.
    public let objects: [InspectorObject]

    /// Creates a catalogue snapshot.
    public init(complete: Bool, observedSince: String, namespace: String, objects: [InspectorObject]) {
        self.complete = complete
        self.observedSince = observedSince
        self.namespace = namespace
        self.objects = objects
    }
}
