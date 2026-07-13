// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import XCTest
@testable import CoatySwift

final class PayloadCoderTests: XCTestCase {
    func testCoreObjectRoundTripPreservesRequiredAndOptionalFields() {
        _ = Log.objectType
        let objectId = CoatyUUID(uuidString: "01234567-89ab-4cde-8fab-0123456789ab")!
        let log = Log(
            logLevel: .warning,
            logMessage: "temperature high",
            logDate: "2026-07-13T12:00:00Z",
            name: "plant log",
            objectId: objectId,
            logTags: ["plant", "alert"],
            logLabels: ["line": 4, "active": true]
        )
        log.externalId = "legacy-17"
        log.isDeactivated = false

        let encoded = PayloadCoder.encode(log)
        let decoded: Log? = PayloadCoder.decode(encoded)

        XCTAssertEqual(decoded?.objectId, objectId)
        XCTAssertEqual(decoded?.objectType, Log.objectType)
        XCTAssertEqual(decoded?.name, "plant log")
        XCTAssertEqual(decoded?.externalId, "legacy-17")
        XCTAssertEqual(decoded?.isDeactivated, false)
        XCTAssertEqual(decoded?.logLevel, .warning)
        XCTAssertEqual(decoded?.logMessage, "temperature high")
        XCTAssertEqual(decoded?.logTags ?? [], ["plant", "alert"])
        // Type-erased JSON numbers intentionally decode as Double.
        XCTAssertEqual(decoded?.logLabels?["line"] as? Double, 4)
        XCTAssertEqual(decoded?.logLabels?["active"] as? Bool, true)
    }

    func testCommunicationEventRoundTripPreservesPrivateData() throws {
        _ = Identity.objectType
        let identity = Identity(name: "Axoloty agent")
        let event = try AdvertiseEvent.with(
            object: identity,
            privateData: ["revision": 7, "ready": true]
        )

        let decoded: AdvertiseEvent? = PayloadCoder.decode(PayloadCoder.encode(event))

        XCTAssertEqual(decoded?.data.object.objectId, identity.objectId)
        XCTAssertEqual(decoded?.data.object.name, "Axoloty agent")
        XCTAssertEqual(decoded?.data.privateData?["revision"] as? Double, 7)
        XCTAssertEqual(decoded?.data.privateData?["ready"] as? Bool, true)
    }

    func testDecodeReturnsNilForMalformedAndTypeMismatchedJSON() {
        let malformed: Identity? = PayloadCoder.decode("{not-json")
        let wrongShape: Identity? = PayloadCoder.decode("{\"name\":42}")
        XCTAssertNil(malformed)
        XCTAssertNil(wrongShape)
    }
}
