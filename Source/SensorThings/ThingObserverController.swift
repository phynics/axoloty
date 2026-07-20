// Copyright (c) 2020 Siemens AG. Licensed under the MIT License.

import Foundation

/// Observes Things and Thing-related objects using async event streams.
open class ThingObserverController: Controller {
    /// Observes advertised Thing snapshots.
    public func observeAdvertisedThingsStream() async throws -> AsyncStream<AdvertiseEventSnapshot> {
        try await communicationManager.observeAdvertiseStream(withObjectType: SensorThingsTypes.OBJECT_TYPE_THING)
    }

    /// Discovers Thing response snapshots.
    public func discoverThingsStream() async -> AsyncStream<ResponseEventSnapshot> {
        await communicationManager.publishDiscover(DiscoverEvent.with(objectTypes: [SensorThingsTypes.OBJECT_TYPE_THING]))
    }

    /// Queries Things located at a location.
    public func queryThingsAtLocationStream(locationId: CoatyUUID) async -> AsyncStream<ResponseEventSnapshot> {
        await communicationManager.publishQuery(QueryEvent.with(objectTypes: [SensorThingsTypes.OBJECT_TYPE_THING], objectFilter: nil, objectJoinConditions: nil))
    }
}
