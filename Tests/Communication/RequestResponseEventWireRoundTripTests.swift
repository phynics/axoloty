// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import Axoloty

/// Ordinary-suite round-trip coverage for the request/response event types
/// that are otherwise only exercised by live-wire-on-demand tests
/// (`WIRE_REVERSE_LIVE`, `WIRE_JS_TO_MODERN_LIVE`).
///
/// These are the Coaty communication event families that carry a primary
/// object or a query/retrieve payload. The class bodies were previously at 0%
/// line coverage because the only instantiating tests (wire-compat reverse
/// producers/consumers) are gated behind live CoatyJS reference agents.
@Suite
struct RequestResponseEventWireRoundTripTests {

    // MARK: - QueryEvent

    @Test
    func queryEventObjectTypesRoundTrip() throws {
        let event = QueryEvent.with(objectTypes: ["com.example.Sensor"], objectFilter: nil)
        #expect(event.data.objectTypes == ["com.example.Sensor"])
        #expect(event.data.coreTypes == nil)

        let decoded = try roundTrip(QueryEvent.self, event)
        #expect(decoded.data.objectTypes == ["com.example.Sensor"])
        #expect(decoded.data.objectFilter != nil) // always emitted, `{}` when nil
    }

    @Test
    func queryEventCoreTypesRoundTrip() throws {
        let event = QueryEvent.with(coreTypes: [.CoatyObject, .Identity])
        #expect(event.data.coreTypes == [.CoatyObject, .Identity])
        #expect(event.data.objectTypes == nil)

        let decoded = try roundTrip(QueryEvent.self, event)
        #expect(decoded.data.coreTypes == [.CoatyObject, .Identity])
        #expect(decoded.data.objectTypes == nil)
    }

    @Test
    func queryEventSingleJoinConditionUsesSingular() throws {
        // The Coaty wire format carries a single join condition in the
        // singular `objectJoinCondition` slot.
        let join = ObjectJoinCondition(
            localProperty: "parentId",
            asProperty: "children"
        )
        let event = QueryEvent.with(objectTypes: ["com.example.Sensor"], objectJoinConditions: [join])

        let decoded = try roundTrip(QueryEvent.self, event)
        #expect(decoded.data.objectJoinCondition != nil)
        #expect(decoded.data.objectJoinConditions == nil)
    }

    @Test
    func queryEventMultipleJoinConditionsUsePlural() throws {
        let join = ObjectJoinCondition(
            localProperty: "parentId",
            asProperty: "children"
        )
        let event = QueryEvent.with(
            objectTypes: ["com.example.Sensor"],
            objectJoinConditions: [join, join]
        )

        let decoded = try roundTrip(QueryEvent.self, event)
        #expect(decoded.data.objectJoinConditions?.count == 2)
        #expect(decoded.data.objectJoinCondition == nil)
    }

    // MARK: - RetrieveEvent

    @Test
    func retrieveEventRoundTripsObjects() throws {
        let object = makeObject()
        let event = RetrieveEvent.with(objects: [object], privateData: ["page": 1])

        let decoded = try roundTrip(RetrieveEvent.self, event)
        #expect(decoded.data.objects.count == 1)
        #expect(decoded.data.objects.first?.objectId == object.objectId)
    }

    @Test
    func retrieveEventWithEmptyObjectsRoundTrips() throws {
        // An empty Retrieve payload is valid on the wire (CoatyJS sends `[]`).
        let event = RetrieveEvent.with(objects: [])
        let decoded = try roundTrip(RetrieveEvent.self, event)
        #expect(decoded.data.objects.isEmpty)
    }

    // MARK: - UpdateEvent

    @Test
    func updateEventRoundTripsObject() throws {
        let object = makeObject()
        let event = try UpdateEvent.with(object: object)

        let decoded = try roundTrip(UpdateEvent.self, event)
        #expect(decoded.data.object.objectId == object.objectId)
        #expect(decoded.data.object.objectType == object.objectType)
    }

    @Test
    func updateEventRejectsInvalidObjectType() {
        let invalid = CoatyObject(
            coreType: .CoatyObject,
            objectType: "invalid/type",
            objectId: CoatyUUID(),
            name: "bad"
        )
        #expect(throws: AxolotyError.self) {
            try UpdateEvent.with(object: invalid)
        }
    }

    // MARK: - CompleteEvent

    @Test
    func completeEventRoundTripsObjectAndPrivateData() throws {
        let object = makeObject()
        let event = CompleteEvent.with(object: object, privateData: ["done": true])

        let decoded = try roundTrip(CompleteEvent.self, event)
        #expect(decoded.data.object?.objectId == object.objectId)
        let privateData = try #require(decoded.data.privateData)
        #expect(privateData["done"] as? Bool == true)
    }

    @Test
    func completeEventWithOmittedFieldsDecodesAsNil() throws {
        let json = #"{"type":"COM"}"#
        let event: CompleteEvent = try PayloadCoder.decode(json)
        #expect(event.data.object == nil)
        #expect(event.data.privateData == nil)
    }

    // MARK: - Helpers

    private func roundTrip<T: Decodable>(_ type: T.Type, _ event: CommunicationEvent<some CommunicationEventData>) throws -> T {
        let encoded = try JSONEncoder().encode(event)
        return try JSONDecoder().decode(type, from: encoded)
    }

    private func makeObject() -> CoatyObject {
        CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.example.Sensor",
            objectId: CoatyUUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            name: "sensor-1"
        )
    }
}
