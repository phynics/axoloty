// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import Axoloty

/// Verifies that event snapshots preserve consumer-visible metadata and
/// representative event data fields without referencing legacy event classes.
@Suite
struct EventSnapshotMetadataTests {

    private let sourceId = "550e8400-e29b-41d4-a716-446655440001"
    private let objectId = "550e8400-e29b-41d4-a716-446655440000"

    @Test
    func advertiseSnapshotPreservesMetadataAndObject() throws {
        let snapshot = AdvertiseEventSnapshot(
            sourceId: sourceId,
            eventTypeFilter: ":coaty.Custom",
            object: sampleObject(),
            privateData: sampleData()
        )

        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.eventTypeFilter == ":coaty.Custom")
        #expect(snapshot.object.objectId == objectId)
        #expect(snapshot.object.coreType == .CoatyObject)
        #expect(snapshot.privateData == sampleData())

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.sourceId == sourceId)
        #expect(roundTripped.eventTypeFilter == ":coaty.Custom")
        #expect(roundTripped.object.objectId == objectId)
        #expect(roundTripped.privateData == sampleData())
    }

    @Test
    func deadvertiseSnapshotPreservesMetadataAndObjectIds() throws {
        let snapshot = DeadvertiseEventSnapshot(
            sourceId: sourceId,
            objectIds: [objectId]
        )

        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.objectIds == [objectId])

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.sourceId == sourceId)
        #expect(roundTripped.objectIds == [objectId])
    }

    @Test
    func channelSnapshotPreservesMetadataObjectsAndChannelId() throws {
        let snapshot = ChannelEventSnapshot(
            sourceId: sourceId,
            objects: [sampleObject()],
            channelId: "channel-a",
            eventTypeFilter: "channel-a",
            privateData: sampleData()
        )

        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.channelId == "channel-a")
        #expect(snapshot.eventTypeFilter == "channel-a")
        #expect(snapshot.objects?.count == 1)
        #expect(snapshot.objects?.first?.objectId == objectId)
        #expect(snapshot.privateData == sampleData())

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.sourceId == sourceId)
        #expect(roundTripped.channelId == "channel-a")
        #expect(roundTripped.eventTypeFilter == "channel-a")
        #expect(roundTripped.objects?.first?.objectId == objectId)
    }

    @Test
    func updateSnapshotPreservesMetadataAndObject() throws {
        let snapshot = UpdateEventSnapshot(
            sourceId: sourceId,
            eventTypeFilter: "CoatyObject",
            object: sampleObject()
        )

        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.eventTypeFilter == "CoatyObject")
        #expect(snapshot.object.objectId == objectId)

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.sourceId == sourceId)
        #expect(roundTripped.eventTypeFilter == "CoatyObject")
        #expect(roundTripped.object.objectId == objectId)
    }

    @Test
    func discoverSnapshotPreservesMetadataAndTypeFilters() throws {
        let snapshot = DiscoverEventSnapshot(
            sourceId: sourceId,
            externalId: "external-1",
            objectId: objectId,
            objectTypes: ["coaty.Custom"],
            coreTypes: [.CoatyObject]
        )

        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.externalId == "external-1")
        #expect(snapshot.objectId == objectId)
        #expect(snapshot.objectTypes == ["coaty.Custom"])
        #expect(snapshot.coreTypes == [.CoatyObject])

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.sourceId == sourceId)
        #expect(roundTripped.externalId == "external-1")
        #expect(roundTripped.objectId == objectId)
        #expect(roundTripped.objectTypes == ["coaty.Custom"])
        #expect(roundTripped.coreTypes == [.CoatyObject])
    }

    @Test
    func callSnapshotPreservesMetadataOperationAndParameters() throws {
        let snapshot = CallEventSnapshot(
            sourceId: sourceId,
            operation: "doThing",
            parameters: sampleData(),
            filter: sampleData()
        )

        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.operation == "doThing")
        #expect(snapshot.parameters == sampleData())
        #expect(snapshot.filter == sampleData())

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.sourceId == sourceId)
        #expect(roundTripped.operation == "doThing")
        #expect(roundTripped.parameters == sampleData())
        #expect(roundTripped.filter == sampleData())
    }

    @Test
    func querySnapshotPreservesMetadataFiltersAndJoinConditions() throws {
        let snapshot = QueryEventSnapshot(
            sourceId: sourceId,
            objectTypes: ["coaty.Custom"],
            coreTypes: [.CoatyObject],
            objectFilter: sampleData(),
            objectJoinConditions: [sampleData()],
            objectJoinCondition: nil
        )

        #expect(snapshot.sourceId == sourceId)
        #expect(snapshot.objectTypes == ["coaty.Custom"])
        #expect(snapshot.coreTypes == [.CoatyObject])
        #expect(snapshot.objectFilter == sampleData())
        #expect(snapshot.objectJoinConditions?.count == 1)

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.sourceId == sourceId)
        #expect(roundTripped.objectTypes == ["coaty.Custom"])
        #expect(roundTripped.coreTypes == [.CoatyObject])
        #expect(roundTripped.objectFilter == sampleData())
        #expect(roundTripped.objectJoinConditions?.count == 1)
    }

    @Test
    func querySnapshotPreservesSingleJoinCondition() throws {
        let snapshot = QueryEventSnapshot(
            sourceId: sourceId,
            objectTypes: ["coaty.Custom"],
            objectFilter: nil,
            objectJoinConditions: nil,
            objectJoinCondition: sampleData()
        )

        #expect(snapshot.objectJoinCondition == sampleData())
        #expect(snapshot.objectJoinConditions == nil)

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.objectJoinCondition == sampleData())
        #expect(roundTripped.objectJoinConditions == nil)
    }

    @Test
    func coatyObjectSnapshotPreservesTypedFields() throws {
        let payload = Data("{\"custom\":\"value\"}".utf8)
        let snapshot = CoatyObjectSnapshot(
            objectId: objectId,
            coreType: .CoatyObject,
            objectType: "coaty.CoatyObject",
            name: "Sample Object",
            externalId: "external-1",
            parentObjectId: "550e8400-e29b-41d4-a716-446655440002",
            locationId: "550e8400-e29b-41d4-a716-446655440003",
            isDeactivated: true,
            payload: payload
        )

        #expect(snapshot.objectId == objectId)
        #expect(snapshot.coreType == .CoatyObject)
        #expect(snapshot.objectType == "coaty.CoatyObject")
        #expect(snapshot.name == "Sample Object")
        #expect(snapshot.externalId == "external-1")
        #expect(snapshot.parentObjectId == "550e8400-e29b-41d4-a716-446655440002")
        #expect(snapshot.locationId == "550e8400-e29b-41d4-a716-446655440003")
        #expect(snapshot.isDeactivated == true)
        #expect(snapshot.payload == payload)

        let roundTripped = try roundTrip(snapshot)
        #expect(roundTripped.coreType == .CoatyObject)
        #expect(roundTripped.objectType == "coaty.CoatyObject")
        #expect(roundTripped.payload == payload)
    }
}

private func sampleObject() -> CoatyObjectSnapshot {
    CoatyObjectSnapshot(
        objectId: "550e8400-e29b-41d4-a716-446655440000",
        coreType: .CoatyObject,
        objectType: "coaty.CoatyObject",
        name: "Sample Object"
    )
}

private func sampleData() -> Data {
    Data("{\"key\":\"value\"}".utf8)
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(value)
    return try decoder.decode(T.self, from: data)
}
