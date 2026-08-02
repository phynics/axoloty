// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import Testing

@Test
func catalogueStoreStartsEmpty() async {
    let store = InspectorCatalogueStore(observedSince: "2026-01-01T00:00:00Z", namespace: "test")
    let snapshot = await store.snapshot(filter: ObjectCatalogueFilter())
    #expect(snapshot.complete == false)
    #expect(snapshot.objects.isEmpty)
    #expect(snapshot.namespace == "test")
    let count = await store.count
    #expect(count == 0)
}

@Test
func catalogueStoreAppliesAndRetrievesObject() async {
    let store = InspectorCatalogueStore(observedSince: "2026-01-01T00:00:00Z", namespace: "test")
    let object = InspectorObject(
        objectId: "00000000-0000-4000-8000-000000000001",
        coreType: "Identity",
        objectType: "coaty.Identity",
        name: "Agent A"
    )
    await store.apply(object)
    let retrieved = await store.object(id: "00000000-0000-4000-8000-000000000001")
    #expect(retrieved?.name == "Agent A")
    let count = await store.count
    #expect(count == 1)
}

@Test
func catalogueStoreRemovesObjects() async {
    let store = InspectorCatalogueStore(observedSince: "2026-01-01T00:00:00Z", namespace: "test")
    let object = InspectorObject(
        objectId: "00000000-0000-4000-8000-000000000001",
        coreType: "Identity",
        objectType: "coaty.Identity",
        name: "Agent A"
    )
    await store.apply(object)
    await store.remove(objectIds: ["00000000-0000-4000-8000-000000000001"])
    let count = await store.count
    #expect(count == 0)
}

@Test
func catalogueStoreSnapshotIsAlwaysIncomplete() async {
    let store = InspectorCatalogueStore(observedSince: "2026-01-01T00:00:00Z", namespace: "test")
    let object = InspectorObject(
        objectId: "00000000-0000-4000-8000-000000000001",
        coreType: "Identity",
        objectType: "coaty.Identity"
    )
    await store.apply(object)
    let snapshot = await store.snapshot(filter: ObjectCatalogueFilter())
    #expect(snapshot.complete == false)
}

@Test
func catalogueStoreDeduplicatesByObjectId() async {
    let store = InspectorCatalogueStore(observedSince: "2026-01-01T00:00:00Z", namespace: "test")
    let id = "00000000-0000-4000-8000-000000000001"
    await store.apply(InspectorObject(objectId: id, coreType: "Identity", objectType: "coaty.Identity", name: "Old"))
    await store.apply(InspectorObject(objectId: id, coreType: "Identity", objectType: "coaty.Identity", name: "New"))
    let count = await store.count
    #expect(count == 1)
    let retrieved = await store.object(id: id)
    #expect(retrieved?.name == "New")
}

@Test
func catalogueStoreFilterMatchesByCoreType() async {
    let store = InspectorCatalogueStore(observedSince: "2026-01-01T00:00:00Z", namespace: "test")
    await store.apply(InspectorObject(objectId: "id-1", coreType: "Identity", objectType: "coaty.Identity"))
    await store.apply(InspectorObject(objectId: "id-2", coreType: "Task", objectType: "coaty.Task"))
    let filter = ObjectCatalogueFilter(coreType: "Identity", objectType: nil, objectId: nil, sourceId: nil)
    let snapshot = await store.snapshot(filter: filter)
    #expect(snapshot.objects.count == 1)
    #expect(snapshot.objects.first?.coreType == "Identity")
}

@Test
func discoveryRequestHasSelectorWhenAnyFieldProvided() {
    let req = InspectorDiscoveryRequest(coreType: "Identity")
    #expect(req.hasSelector)
    let req2 = InspectorDiscoveryRequest()
    #expect(!req2.hasSelector)
}

@Test
func discoveryRequestRejectsInvalidTypedSelectors() {
    let missingSelector = InspectorDiscoveryRequest()
    let invalidUUID = InspectorDiscoveryRequest(objectId: "not-a-uuid")
    let invalidCoreType = InspectorDiscoveryRequest(coreType: "UnknownCoreType")

    #expect(throws: InspectorError.invalidArguments(reason: "at least one selector (coreType, objectType, or objectId) is required")) {
        try missingSelector.makeDiscoverEvent()
    }
    #expect(throws: InspectorError.invalidArguments(reason: "objectId must be a valid UUID: not-a-uuid")) {
        try invalidUUID.makeDiscoverEvent()
    }
    #expect(throws: InspectorError.invalidArguments(reason: "coreType must be a known core type: UnknownCoreType")) {
        try invalidCoreType.makeDiscoverEvent()
    }
}

@Test
func discoveryRequestPreservesSelectorPrecedenceForValidSelectors() throws {
    let request = InspectorDiscoveryRequest(
        coreType: "Identity",
        objectType: "coaty.object.Identity",
        objectId: "00000000-0000-4000-8000-000000000001"
    )

    let event = try request.makeDiscoverEvent()

    #expect(event.data.objectId?.string == "00000000-0000-4000-8000-000000000001")
    #expect(event.data.objectTypes == nil)
    #expect(event.data.coreTypes == nil)
}

@Test
func catalogueSnapshotIsCodable() throws {
    let snapshot = InspectorCatalogueSnapshot(
        complete: false,
        observedSince: "2026-01-01T00:00:00Z",
        namespace: "test",
        objects: [
            InspectorObject(objectId: "id-1", coreType: "Identity", objectType: "coaty.Identity")
        ]
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(InspectorCatalogueSnapshot.self, from: data)
    #expect(decoded == snapshot)
}
