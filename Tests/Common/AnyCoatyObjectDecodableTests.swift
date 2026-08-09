// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import IkigaJSON
import Testing
import Axoloty

@Suite
struct AnyCoatyObjectDecodableTests {
    @Test
    func exposesDecodedObjectThroughPublicTypeErasedAccess() throws {
        _ = Identity.objectType
        let envelope = try IkigaJSONDecoder().decode(
            Envelope.self,
            from: "{\"object\":{\"coreType\":\"Identity\",\"objectType\":\"coaty.Identity\",\"objectId\":\"01234567-89ab-4cde-8fab-0123456789ab\",\"name\":\"agent\"}}"
        )

        let object: CoatyObject = envelope.object.object
        let identity = try #require(object as? Identity)

        #expect(object.objectType == Identity.objectType)
        #expect(identity.name == "agent")
    }

    @Test
    func typeErasedAccessRetainsTheDecodedObjectReference() throws {
        _ = Identity.objectType
        let envelope = try IkigaJSONDecoder().decode(
            Envelope.self,
            from: "{\"object\":{\"coreType\":\"Identity\",\"objectType\":\"coaty.Identity\",\"objectId\":\"01234567-89ab-4cde-8fab-0123456789ab\",\"name\":\"agent\"}}"
        )

        let object = envelope.object.object
        object.name = "updated"

        #expect(envelope.object.object === object)
        #expect(envelope.object.object.name == "updated")
    }

    private struct Envelope: Decodable {
        let object: AnyCoatyObjectDecodable
    }
}
