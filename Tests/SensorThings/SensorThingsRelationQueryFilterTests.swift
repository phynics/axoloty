// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  SensorThingsRelationQueryFilterTests.swift
//  Axoloty

@testable import Axoloty
import Foundation
import Testing

/// Regression tests for issue #445 / P1-7 relation query filters.
///
/// `SensorObserverController.querySensorsOfThingsStream(thingId:)` and
/// `ThingObserverController.queryThingsAtLocationStream(locationId:)` used to
/// ignore their id argument (`objectFilter: nil`), returning every object of
/// the queried type regardless of the requested relation. They now attach an
/// `Equals` ``ObjectFilter`` on the relation key (`parentObjectId` /
/// `locationId`).
///
/// These tests pin that the filters built the same way the controllers build
/// them match exactly the objects in the requested relation and reject
/// unrelated ones.
@Suite
struct SensorThingsRelationQueryFilterTests {

    /// The `querySensorsOfThingsStream` filter must match a Sensor whose
    /// `parentObjectId` equals the requested thing id and reject a Sensor
    /// related to a different thing.
    @Test
    func sensorsOfThingsFilterMatchesByParentObjectId() throws {
        // Mirror the filter built in SensorObserverController.
        let thingId = try #require(CoatyUUID(uuidString: "4c480c29-f65f-496f-8005-03e7503eec2b"))
        let filter = try ObjectFilter.buildWithCondition { builder in
            builder.condition = try ObjectFilterCondition.build { cb in
                cb.property = ObjectFilterProperty("parentObjectId")
                cb.expression = FilterOperations.equals(FilterOperand(thingId))
            }
        }

        let matchingSensor = Sensor(
            description: "", encodingType: "", metadata: "null",
            unitOfMeasurement: UnitOfMeasurement(name: "", symbol: "", definition: ""),
            observationType: .measurement,
            observedProperty: ObservedProperty(name: "T", definition: "", description: ""),
            name: "s",
            parentObjectId: thingId
        )
        let unrelatedSensor = Sensor(
            description: "", encodingType: "", metadata: "null",
            unitOfMeasurement: UnitOfMeasurement(name: "", symbol: "", definition: ""),
            observationType: .measurement,
            observedProperty: ObservedProperty(name: "T", definition: "", description: ""),
            name: "s2",
            parentObjectId: CoatyUUID()
        )

        #expect(ObjectMatcher.matchesFilter(obj: matchingSensor, filter: filter))
        #expect(!ObjectMatcher.matchesFilter(obj: unrelatedSensor, filter: filter))
    }

    /// The `queryThingsAtLocationStream` filter must match a Thing whose
    /// `locationId` equals the requested location id and reject a Thing at a
    /// different location.
    @Test
    func thingsAtLocationFilterMatchesByLocationId() throws {
        // Mirror the filter built in ThingObserverController.
        let locationId = try #require(CoatyUUID(uuidString: "14119642-ee6a-4596-bf34-d8a3436290d3"))
        let filter = try ObjectFilter.buildWithCondition { builder in
            builder.condition = try ObjectFilterCondition.build { cb in
                cb.property = ObjectFilterProperty("locationId")
                cb.expression = FilterOperations.equals(FilterOperand(locationId))
            }
        }

        let matchingThing = Thing(description: "", name: "t1", locationId: locationId)
        let unrelatedThing = Thing(description: "", name: "t2", locationId: CoatyUUID())

        #expect(ObjectMatcher.matchesFilter(obj: matchingThing, filter: filter))
        #expect(!ObjectMatcher.matchesFilter(obj: unrelatedThing, filter: filter))
    }

    /// UUID-value filtering survives a wire round trip (operand decodes as a
    /// String), matching the regression locked for `objectId` in issue #102.
    @Test
    func relationFilterSurvivesWireRoundTrip() throws {
        let thingId = try #require(CoatyUUID(uuidString: "4c480c29-f65f-496f-8005-03e7503eec2b"))
        let filter = try ObjectFilter.buildWithCondition { builder in
            builder.condition = try ObjectFilterCondition.build { cb in
                cb.property = ObjectFilterProperty("parentObjectId")
                cb.expression = FilterOperations.equals(FilterOperand(thingId))
            }
        }

        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(ObjectFilter.self, from: data)

        let matchingSensor = Sensor(
            description: "", encodingType: "", metadata: "null",
            unitOfMeasurement: UnitOfMeasurement(name: "", symbol: "", definition: ""),
            observationType: .measurement,
            observedProperty: ObservedProperty(name: "T", definition: "", description: ""),
            name: "s",
            parentObjectId: thingId
        )
        #expect(ObjectMatcher.matchesFilter(obj: matchingSensor, filter: decoded))
        let unrelatedSensor = Sensor(
            description: "", encodingType: "", metadata: "null",
            unitOfMeasurement: UnitOfMeasurement(name: "", symbol: "", definition: ""),
            observationType: .measurement,
            observedProperty: ObservedProperty(name: "T", definition: "", description: ""),
            name: "s2",
            parentObjectId: CoatyUUID()
        )
        #expect(!ObjectMatcher.matchesFilter(obj: unrelatedSensor, filter: decoded))
    }
}