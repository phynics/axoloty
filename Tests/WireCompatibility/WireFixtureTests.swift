// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import CoatySwift

@Suite
struct WireFixtureTests {
    @Test
    func testAdvertiseFixtureDecodesAndRoundTripsSemantically() throws {
        let fixture = try fixtureData(named: "advertise-coaty-object")
        let fixtureJSON = try #require(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let payload = try #require(String(data: fixture, encoding: .utf8))

        let event: AdvertiseEvent = try #require(PayloadCoder.decode(payload))
        #expect((event.data.object.coreType) == (.CoatyObject))
        #expect((event.data.object.objectType) == ("coaty.CoatyObject"))
        #expect((event.data.object.objectId.string) == ("00000000-0000-4000-8000-000000000001"))
        #expect((event.data.object.name) == ("Wire fixture"))

        let encoded = try #require(event.json.data(using: .utf8))
        let encodedJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect((encodedJSON) == (fixtureJSON), "JSON key order is irrelevant, but wire values and shape must remain stable")
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
