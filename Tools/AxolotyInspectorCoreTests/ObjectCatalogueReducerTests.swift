// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation
import Testing

@Suite
struct ObjectCatalogueReducerTests {

    // MARK: - Advertise insertion

    @Test
    func advertiseInsertsNewObject() {
        let reducer = ObjectCatalogueReducer()
        let object = InspectorObject(
            objectId: "obj-1", coreType: "Identity",
            objectType: "coaty.object.Identity", name: "Agent A"
        )
        let (catalogue, mutation) = reducer.reduceAdvertise(object, into: ObjectCatalogue())

        #expect(mutation == .inserted(object))
        #expect(catalogue.objectsById["obj-1"] == object)
        #expect(catalogue.objectsById.count == 1)
    }

    @Test
    func repeatedIdenticalAdvertiseReturnsUnchanged() {
        let reducer = ObjectCatalogueReducer()
        let object = InspectorObject(
            objectId: "obj-1", coreType: "Identity",
            objectType: "coaty.object.Identity", name: "Agent A"
        )
        let (cat1, _) = reducer.reduceAdvertise(object, into: ObjectCatalogue())
        let (cat2, mutation) = reducer.reduceAdvertise(object, into: cat1)

        #expect(mutation == .unchanged(object))
        #expect(cat2.objectsById.count == 1)
        #expect(cat2 == cat1)
    }

    @Test
    func changedAdvertiseReturnsUpdated() {
        let reducer = ObjectCatalogueReducer()
        let original = InspectorObject(
            objectId: "obj-1", coreType: "Sensor",
            objectType: "com.example.Sensor", name: "Temp"
        )
        let updated = InspectorObject(
            objectId: "obj-1", coreType: "Sensor",
            objectType: "com.example.Sensor", name: "Temperature"
        )
        let (cat1, _) = reducer.reduceAdvertise(original, into: ObjectCatalogue())
        let (cat2, mutation) = reducer.reduceAdvertise(updated, into: cat1)

        if case let .updated(prev, curr) = mutation {
            #expect(prev == original)
            #expect(curr == updated)
        } else {
            Issue.record("Expected .updated mutation")
        }
        #expect(cat2.objectsById["obj-1"] == updated)
    }

    @Test
    func differentSourceIdCountsAsUpdate() {
        let reducer = ObjectCatalogueReducer()
        let original = InspectorObject(
            objectId: "obj-1", coreType: "Identity",
            objectType: "coaty.object.Identity", name: "Agent", sourceId: "src-a"
        )
        let reAdvertised = InspectorObject(
            objectId: "obj-1", coreType: "Identity",
            objectType: "coaty.object.Identity", name: "Agent", sourceId: "src-b"
        )
        let (cat1, _) = reducer.reduceAdvertise(original, into: ObjectCatalogue())
        let (_, mutation) = reducer.reduceAdvertise(reAdvertised, into: cat1)

        if case .updated = mutation {
        } else {
            Issue.record("Expected .updated mutation for different sourceId")
        }
    }

    // MARK: - Deadvertise removal

    @Test
    func deadvertiseRemovesOneObject() {
        let reducer = ObjectCatalogueReducer()
        let object = InspectorObject(
            objectId: "obj-1", coreType: "Identity",
            objectType: "coaty.object.Identity", name: "Agent"
        )
        let (cat1, _) = reducer.reduceAdvertise(object, into: ObjectCatalogue())
        let results = reducer.reduceDeadvertise(["obj-1"], into: cat1)

        #expect(results.count == 1)
        if case .removed(let removed) = results[0].1 {
            #expect(removed == object)
        } else {
            Issue.record("Expected .removed mutation")
        }
        #expect(results[0].0.objectsById.isEmpty)
    }

    @Test
    func deadvertiseRemovesMultipleObjects() {
        let reducer = ObjectCatalogueReducer()
        let obj1 = InspectorObject(objectId: "a", coreType: "Identity", objectType: "t", name: "A")
        let obj2 = InspectorObject(objectId: "b", coreType: "Sensor", objectType: "t2", name: "B")
        var cat = ObjectCatalogue()
        cat = reducer.reduceAdvertise(obj1, into: cat).0
        cat = reducer.reduceAdvertise(obj2, into: cat).0

        let results = reducer.reduceDeadvertise(["a", "b"], into: cat)

        #expect(results.count == 2)
        if case .removed = results[0].1 {} else { Issue.record("Expected .removed for first") }
        if case .removed = results[1].1 {} else { Issue.record("Expected .removed for second") }
        #expect(results[1].0.objectsById.isEmpty)
    }

    @Test
    func unknownObjectRemovalIsNonfatal() {
        let reducer = ObjectCatalogueReducer()
        let results = reducer.reduceDeadvertise(["unknown-id"], into: ObjectCatalogue())

        #expect(results.count == 1)
        if case let .removalOfUnknownObject(id) = results[0].1 {
            #expect(id == "unknown-id")
        } else {
            Issue.record("Expected .removalOfUnknownObject")
        }
    }

    // MARK: - Filter

    @Test
    func filterCombinesWithAndSemantics() {
        let filter = ObjectCatalogueFilter(coreType: "Sensor", objectType: "com.example.Sensor")
        let matching = InspectorObject(objectId: "1", coreType: "Sensor", objectType: "com.example.Sensor")
        let wrongCore = InspectorObject(objectId: "2", coreType: "Identity", objectType: "com.example.Sensor")
        let wrongType = InspectorObject(objectId: "3", coreType: "Sensor", objectType: "com.example.Other")

        #expect(filter.matches(matching))
        #expect(!filter.matches(wrongCore))
        #expect(!filter.matches(wrongType))
    }

    @Test
    func filterByObjectId() {
        let filter = ObjectCatalogueFilter(objectId: "target-id")
        let matching = InspectorObject(objectId: "target-id", coreType: "X", objectType: "Y")
        let nonMatching = InspectorObject(objectId: "other-id", coreType: "X", objectType: "Y")

        #expect(filter.matches(matching))
        #expect(!filter.matches(nonMatching))
    }

    @Test
    func filterBySourceId() {
        let filter = ObjectCatalogueFilter(sourceId: "src-1")
        let matching = InspectorObject(objectId: "1", coreType: "X", objectType: "Y", sourceId: "src-1")
        let nonMatching = InspectorObject(objectId: "2", coreType: "X", objectType: "Y", sourceId: "src-2")

        #expect(filter.matches(matching))
        #expect(!filter.matches(nonMatching))
    }

    @Test
    func filterRejectsNonMatchingAdvertise() {
        let reducer = ObjectCatalogueReducer(filter: ObjectCatalogueFilter(coreType: "Sensor"))
        let identity = InspectorObject(objectId: "1", coreType: "Identity", objectType: "t")
        let (cat, mutation) = reducer.reduceAdvertise(identity, into: ObjectCatalogue())

        #expect(mutation == nil)
        #expect(cat.objectsById.isEmpty)
    }

    @Test
    func filteredAdvertiseRemovesExistingObjectWhenItStopsMatching() {
        let reducer = ObjectCatalogueReducer(filter: ObjectCatalogueFilter(coreType: "Sensor"))
        let sensor = InspectorObject(objectId: "1", coreType: "Sensor", objectType: "com.example.Sensor")
        let identity = InspectorObject(objectId: "1", coreType: "Identity", objectType: "coaty.object.Identity")

        let (cat1, insertedMutation) = reducer.reduceAdvertise(sensor, into: ObjectCatalogue())
        let (cat2, mutation) = reducer.reduceAdvertise(identity, into: cat1)

        #expect(insertedMutation == .inserted(sensor))
        #expect(mutation == .removed(sensor))
        #expect(cat2.objectsById.isEmpty)
    }

    @Test
    func deadvertiseRemovesPreviouslyFilteredEntries() {
        let reducer = ObjectCatalogueReducer(filter: ObjectCatalogueFilter(coreType: "Sensor"))
        let sensor = InspectorObject(objectId: "s1", coreType: "Sensor", objectType: "com.example.Sensor")
        let identity = InspectorObject(objectId: "i1", coreType: "Identity", objectType: "coaty.object.Identity")

        let (cat1, m1) = reducer.reduceAdvertise(sensor, into: ObjectCatalogue())
        let (cat2, m2) = reducer.reduceAdvertise(identity, into: cat1)

        #expect(m1 != nil)
        #expect(m2 == nil)
        #expect(cat2.objectsById.count == 1)

        let results = reducer.reduceDeadvertise(["s1"], into: cat2)
        if case .removed = results[0].1 {} else { Issue.record("Expected .removed") }
        #expect(results[0].0.objectsById.isEmpty)
    }

    // MARK: - Payload and private data

    @Test
    func fullPayloadOmittedByDefault() {
        let object = InspectorObject(
            objectId: "1", coreType: "Sensor", objectType: "t",
            name: "S", payload: "{\"temp\":42}", privateData: "{\"secret\":true}"
        )
        let factory = InspectorRecordFactory(namespace: "ns")
        let record = factory.record(for: .inserted(object), timestamp: "2026-07-31T00:00:00Z")!

        #expect(record.payload == nil)
        #expect(record.privateData == nil)
    }

    @Test
    func payloadIncludedWhenFullFlagSet() {
        let object = InspectorObject(
            objectId: "1", coreType: "Sensor", objectType: "t",
            name: "S", payload: "{\"temp\":42}"
        )
        let factory = InspectorRecordFactory(namespace: "ns", includePayload: true)
        let record = factory.record(for: .inserted(object), timestamp: "2026-07-31T00:00:00Z")!

        #expect(record.payload == "{\"temp\":42}")
        #expect(record.privateData == nil)
    }

    @Test
    func privateDataRequiresExplicitFlag() {
        let object = InspectorObject(
            objectId: "1", coreType: "Sensor", objectType: "t",
            name: "S", payload: "{\"temp\":42}", privateData: "{\"secret\":true}"
        )
        let factory = InspectorRecordFactory(namespace: "ns", includePayload: true, includePrivateData: true)
        let record = factory.record(for: .inserted(object), timestamp: "2026-07-31T00:00:00Z")!

        #expect(record.payload == "{\"temp\":42}")
        #expect(record.privateData == "{\"secret\":true}")
    }

    @Test
    func fullDoesNotImplyPrivateData() {
        let object = InspectorObject(
            objectId: "1", coreType: "Sensor", objectType: "t",
            name: "S", payload: "{\"temp\":42}", privateData: "{\"secret\":true}"
        )
        let factory = InspectorRecordFactory(namespace: "ns", includePayload: true)
        let record = factory.record(for: .inserted(object), timestamp: "2026-07-31T00:00:00Z")!

        #expect(record.payload == "{\"temp\":42}")
        #expect(record.privateData == nil)
    }

    @Test
    func unchangedMutationProducesNoRecord() {
        let object = InspectorObject(objectId: "1", coreType: "X", objectType: "Y")
        let record = InspectorRecordFactory(namespace: "ns")
            .record(for: .unchanged(object), timestamp: "2026-07-31T00:00:00Z")

        #expect(record == nil)
    }

    @Test
    func removalOfUnknownObjectProducesNoRecordByDefault() {
        let record = InspectorRecordFactory(namespace: "ns")
            .record(for: .removalOfUnknownObject(objectId: "unknown"), timestamp: "2026-07-31T00:00:00Z")

        #expect(record == nil)
    }

    @Test
    func removalOfUnknownObjectProducesRecordInVerboseMode() {
        let record = InspectorRecordFactory(namespace: "ns")
            .record(for: .removalOfUnknownObject(objectId: "unknown"), timestamp: "2026-07-31T00:00:00Z", verbose: true)

        #expect(record != nil)
        #expect(record?.kind == .deadvertise)
        #expect(record?.removedObjectIds == ["unknown"])
    }
}
