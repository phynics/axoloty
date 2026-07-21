// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import IkigaJSON
import Testing
@testable import Axoloty

@Suite
struct IkigaJSONDecoderSeamTests {
    @Test
    func dependencyResolvesAndParsesJSONObject() throws {
        let json = """
        {"object":{"name":"plant","values":[1,2.5,true],"nested":{"ready":true}}}
        """
        let object = try JSONObject(data: Data(json.utf8))
        let nested = try #require(object["object"]?.object)
        let values = try #require(nested["values"]?.array)

        #expect(nested["name"]?.string == "plant")
        #expect(values[0].int == 1)
        #expect(values[1].double == 2.5)
        #expect(values[2].bool == true)
        #expect(nested["nested"]?.object?["ready"]?.bool == true)

        _ = Identity.objectType
        struct Envelope: Decodable {
            let object: AnyCoatyObjectDecodable
        }
        let envelope = try IkigaJSONDecoder().decode(
            Envelope.self,
            from: "{\"object\":{\"coreType\":\"Identity\",\"objectType\":\"coaty.Identity\",\"objectId\":\"01234567-89ab-4cde-8fab-0123456789ab\",\"name\":\"agent\"}}"
        )
        #expect(envelope.object.object.name == "agent")
    }

    @Test
    func ikigaDecoderPreservesDecoderContextLikeFoundation() throws {
        struct ContextReader: Decodable {
            let value: String?

            init(from decoder: any Decoder) throws {
                value = decoder.currentContext(forKey: "site") as? String
            }
        }

        func foundationRead() throws -> (String?, String?) {
            let decoder = JSONDecoder()
            let context = DecodingContextStack()
            decoder.setContext(context, forKey: "site")
            context.push("plant-7")
            let value = try decoder.decode(ContextReader.self, from: Data("{}".utf8))
            return (value.value, context.current as? String)
        }

        func ikigaRead() throws -> (String?, String?) {
            var settings = JSONDecoderSettings()
            let key = CodingUserInfoKey(rawValue: "site")!
            let context = DecodingContextStack()
            context.push("plant-7")
            settings.userInfo[key] = context
            let decoder = IkigaJSONDecoder(settings: settings)
            let value = try decoder.decode(ContextReader.self, from: "{}")
            return (value.value, context.current as? String)
        }

        let foundation = try foundationRead()
        let ikiga = try ikigaRead()

        #expect(foundation.0 == "plant-7")
        #expect(foundation.1 == "plant-7")
        #expect(ikiga.0 == "plant-7")
        #expect(ikiga.1 == "plant-7")
    }

    @Test
    func nestedJSONObjectRetainsBackingStorageAfterParserReturns() throws {
        func parseNested() throws -> JSONObject {
            let data = Data("{\"object\":{\"name\":\"plant\",\"ready\":true}}".utf8)
            let root = try JSONObject(data: data)
            return try #require(root["object"]?.object)
        }

        let nested = try parseNested()
        #expect(nested["name"]?.string == "plant")
        #expect(nested["ready"]?.bool == true)
        #expect(nested.string == "{\"name\":\"plant\",\"ready\":true}")
    }

    @Test
    func programmaticCoatyObjectProducesFreshJSONObjectAfterMutation() throws {
        _ = Log.objectType
        let objectId = try #require(CoatyUUID(uuidString: "01234567-89ab-4cde-8fab-0123456789ab"))
        let log = Log(
            logLevel: .warning,
            logMessage: "before",
            logDate: "2026-07-13T12:00:00Z",
            name: "plant log",
            objectId: objectId,
            logTags: ["plant"],
            logLabels: ["line": 4]
        )

        let before = try JSONObject(data: Data(try PayloadCoder.encode(log).utf8))
        log.logMessage = "after"
        log.logLabels?["line"] = 9
        let after = try JSONObject(data: Data(try PayloadCoder.encode(log).utf8))

        #expect(before["logMessage"]?.string == "before")
        #expect(after["logMessage"]?.string == "after")
        #expect(before["logLabels"]?.object?["line"]?.double == 4 || before["logLabels"]?.object?["line"]?.int == 4)
        #expect(after["logLabels"]?.object?["line"]?.double == 9 || after["logLabels"]?.object?["line"]?.int == 9)
    }
}
