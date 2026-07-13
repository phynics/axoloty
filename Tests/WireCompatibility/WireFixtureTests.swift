// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import XCTest
@testable import CoatySwift

final class WireFixtureTests: XCTestCase {
    func testAdvertiseFixtureDecodesAndRoundTripsSemantically() throws {
        let fixture = try fixtureData(named: "advertise-coaty-object")
        let fixtureJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let payload = try XCTUnwrap(String(data: fixture, encoding: .utf8))

        let event: AdvertiseEvent = try XCTUnwrap(PayloadCoder.decode(payload))
        XCTAssertEqual(event.data.object.coreType, .CoatyObject)
        XCTAssertEqual(event.data.object.objectType, "coaty.CoatyObject")
        XCTAssertEqual(event.data.object.objectId.string, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(event.data.object.name, "Wire fixture")

        let encoded = try XCTUnwrap(event.json.data(using: .utf8))
        let encodedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(encodedJSON, fixtureJSON, "JSON key order is irrelevant, but wire values and shape must remain stable")
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try Data(contentsOf: url)
    }
}
