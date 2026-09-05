// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyObjectModel
import AxolotySensorThingsModel
import AxolotyWire
@testable import AxolotySensorThings

/// The catalogue state machine, exercised without a runtime.
///
/// Before the policy was separated from the registry actor, none of these
/// could be written directly: every one required starting a runtime, driving
/// live events through streams, and waiting for an async condition. They now
/// run synchronously against a value.
@Suite("SensorThings catalogue")
struct SensorThingsCatalogueTests {
    private static let thingUUID = "44444444-4444-4444-8444-444444444444"

    private func snapshot<Schema: SensorThingsTopLevelSchema>(_ object: consuming Object<Schema>) throws
        -> SensorThingsObjectSnapshot<Schema> {
        try SensorThingsObjectSnapshot(object: object)
    }

    private func catalogue(maximumSensors: Int = 4) throws -> SensorThingsCatalogue {
        let uuid = try #require(UUID16(parsing: Self.thingUUID))
        return SensorThingsCatalogue(thingID: ObjectID(uuid: uuid), maximumSensors: maximumSensors)
    }

    @Test("a Thing for another identifier is ignored")
    func foreignThingIsIgnored() throws {
        var subject = try catalogue()
        let other = try snapshot(try fixtureThing(id: "11111111-1111-4111-8111-111111111111"))
        #expect(subject.apply(thing: other).isIgnored)
        #expect(subject.thing == nil)
    }

    @Test("re-applying identical bytes publishes nothing")
    func identicalBytesAreDeduplicated() throws {
        var subject = try catalogue()
        let thing = try snapshot(try fixtureThing(id: Self.thingUUID))
        _ = subject.apply(thing: thing)
        #expect(subject.apply(thing: thing).isIgnored)
    }

    @Test("a Sensor arriving before its Thing is held, then reported when the Thing lands")
    func sensorBeforeThingIsHeldUntilTheThingArrives() throws {
        var subject = try catalogue()
        let sensor = try snapshot(try fixtureSensor(
            id: "22222222-2222-4222-8222-222222222222",
            parentID: Self.thingUUID
        ))
        // No Thing yet: nothing to publish, but the Sensor is retained.
        #expect(subject.apply(sensor: sensor).isIgnored)

        let thing = try snapshot(try fixtureThing(id: Self.thingUUID))
        let outcome = subject.apply(thing: thing)
        #expect(outcome.transitions.count == 1)
        #expect(outcome.transitions.first?.kind == .added)
    }

    @Test("a Sensor parented by another Thing is ignored")
    func foreignParentIsIgnored() throws {
        var subject = try catalogue()
        _ = subject.apply(thing: try snapshot(try fixtureThing(id: Self.thingUUID)))
        let sensor = try snapshot(try fixtureSensor(
            id: "22222222-2222-4222-8222-222222222222",
            parentID: "33333333-3333-4333-8333-333333333333"
        ))
        #expect(subject.apply(sensor: sensor).isIgnored)
    }

    @Test("a new Sensor beyond the limit is refused rather than evicting one")
    func capacityRefusesRatherThanEvicts() throws {
        var subject = try catalogue(maximumSensors: 1)
        _ = subject.apply(thing: try snapshot(try fixtureThing(id: Self.thingUUID)))
        let first = try snapshot(try fixtureSensor(
            id: "22222222-2222-4222-8222-222222222222",
            parentID: Self.thingUUID
        ))
        let second = try snapshot(try fixtureSensor(
            id: "55555555-5555-4555-8555-555555555555",
            parentID: Self.thingUUID
        ))
        #expect(subject.apply(sensor: first).transitions.count == 1)
        #expect(subject.apply(sensor: second).isCapacityExceeded)
        #expect(subject.sortedSensors.count == 1)
    }

    @Test("removing the Thing removes each Sensor with the remaining catalogue")
    func thingRemovalReportsEachRemainingCatalogue() throws {
        var subject = try catalogue()
        let uuid = try #require(UUID16(parsing: Self.thingUUID))
        _ = subject.apply(thing: try snapshot(try fixtureThing(id: Self.thingUUID)))
        for id in ["22222222-2222-4222-8222-222222222222", "55555555-5555-4555-8555-555555555555"] {
            _ = subject.apply(sensor: try snapshot(try fixtureSensor(id: id, parentID: Self.thingUUID)))
        }

        let outcome = subject.remove(ObjectID(uuid: uuid))

        // One transition per Sensor, not a single collapsed removal, and each
        // carries the catalogue as it stood at that step. Reading the total
        // after the removals instead would report an identical empty
        // catalogue for both, hiding the shrink from every subscriber.
        #expect(outcome.transitions.count == 2)
        #expect(outcome.transitions.allSatisfy { $0.kind == .removed })
        #expect(outcome.transitions.map(\.total.count) == [1, 0])
        #expect(subject.thing == nil)
        #expect(subject.sortedSensors.isEmpty)
    }

    @Test("observations are deliverable only for a catalogued Sensor")
    func observationDeliverabilityRequiresACataloguedSensor() throws {
        var subject = try catalogue()
        let sensorUUID = try #require(UUID16(parsing: "22222222-2222-4222-8222-222222222222"))
        let sensorID = ObjectID(uuid: sensorUUID)
        #expect(subject.deliverableSensor(sensorID) == nil)

        _ = subject.apply(thing: try snapshot(try fixtureThing(id: Self.thingUUID)))
        _ = subject.apply(sensor: try snapshot(try fixtureSensor(
            id: "22222222-2222-4222-8222-222222222222",
            parentID: Self.thingUUID
        )))
        #expect(subject.deliverableSensor(sensorID) != nil)
    }
}
