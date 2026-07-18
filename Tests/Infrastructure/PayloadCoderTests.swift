// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import Axoloty

@Suite
struct PayloadCoderTests {
    @Test
    func decoderContextReturnsSendableValues() throws {
        struct ContextReader: Decodable {
            let context: (any Sendable)?

            init(from decoder: any Decoder) throws {
                decoder.pushContext("plant-7", forKey: "site")
                context = decoder.currentContext(forKey: "site")
            }
        }

        let decoder = JSONDecoder()
        decoder.initPushContext(forKey: "site")
        let value = try decoder.decode(ContextReader.self, from: Data("{}".utf8))

        #expect((value.context as? String) == "plant-7")
    }

    @Test
    func testCoreObjectRoundTripPreservesRequiredAndOptionalFields() throws {
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

        let encoded = try PayloadCoder.encode(log)
        let decoded: Log? = try? PayloadCoder.decode(encoded)

        #expect((decoded?.objectId) == (objectId))
        #expect((decoded?.objectType) == (Log.objectType))
        #expect((decoded?.name) == ("plant log"))
        #expect((decoded?.externalId) == ("legacy-17"))
        #expect((decoded?.isDeactivated) == (false))
        #expect((decoded?.logLevel) == (.warning))
        #expect((decoded?.logMessage) == ("temperature high"))
        #expect((decoded?.logTags ?? []) == (["plant", "alert"]))
        // Type-erased JSON numbers intentionally decode as Double.
        #expect((decoded?.logLabels?["line"] as? Double) == (4))
        #expect((decoded?.logLabels?["active"] as? Bool) == (true))
    }

    @Test

    func testCommunicationEventRoundTripPreservesPrivateData() throws {
        _ = Identity.objectType
        let identity = Identity(name: "Axoloty agent")
        let event = try AdvertiseEvent.with(
            object: identity,
            privateData: ["revision": 7, "ready": true]
        )

        let encoded = try PayloadCoder.encode(event)
        let decoded: AdvertiseEvent? = try? PayloadCoder.decode(encoded)

        #expect((decoded?.data.object.objectId) == (identity.objectId))
        #expect((decoded?.data.object.name) == ("Axoloty agent"))
        #expect((decoded?.data.privateData?["revision"] as? Double) == (7))
        #expect((decoded?.data.privateData?["ready"] as? Bool) == (true))
    }

    @Test

    func testDecodeReturnsNilForMalformedAndTypeMismatchedJSON() {
        let malformed: Identity? = try? PayloadCoder.decode("{not-json")
        let wrongShape: Identity? = try? PayloadCoder.decode("{\"name\":42}")
        #expect((malformed) == nil)
        #expect((wrongShape) == nil)
    }

    @Test

    func encodeWrapsUnencodableValueInAxolotyErrorRatherThanCrashing() throws {
        struct HoldsNaN: Codable { let value = Double.nan }

        do {
            _ = try PayloadCoder.encode(HoldsNaN())
            Issue.record("Expected encode to throw for a non-finite double")
        } catch let error as AxolotyError {
            guard case .caught = error else {
                Issue.record("Expected .caught wrapping the encoding failure, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AxolotyError, got \(error)")
        }
    }
}
