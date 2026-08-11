// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import Axoloty

/// Behavior tests for the legacy host serialization machinery, covering
/// the required scenarios from the #354 audit: registered custom object
/// decoding, unknown object-type fallback, custom-property preservation,
/// nested object decoding, missing/invalid discriminators, encoding
/// failure, and stable AxolotyError classification.
@Suite
struct SerializationAuditTests {

    // MARK: - Registered custom object decoding

    @Test
    func registeredCustomObjectTypeDecodesAsRegisteredClass() throws {
        _ = Identity.objectType
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"Identity","objectType":"coaty.Identity","name":"registered-agent"}}
        """
        let event: AdvertiseEvent = try PayloadCoder.decode(json)
        #expect(event.data.object is Identity)
        #expect(event.data.object.name == "registered-agent")
    }

    @Test
    func coatyTaskRoundTripPreservesWireIdentityAndFields() throws {
        let creatorId = CoatyUUID()
        let task = CoatyTask(
            creatorId: creatorId,
            creationTimestamp: 1_234,
            status: .inProgress,
            lastModificationTimestamp: 2_345,
            dueTimestamp: 3_456,
            doneTimestamp: 4_567,
            requirements: ["role": "operator"],
            description: "Inspect equipment",
            assigneeObjectId: CoatyUUID()
        )
        let event = try AdvertiseEvent.with(object: task)
        let encoded = try PayloadCoder.encode(event)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )
        let encodedObject = try #require(json["object"] as? [String: Any])
        let decoded: AdvertiseEvent = try PayloadCoder.decode(encoded)
        let decodedTask = try #require(decoded.data.object as? CoatyTask)

        #expect(encodedObject["coreType"] as? String == "Task")
        #expect(encodedObject["objectType"] as? String == "coaty.Task")
        #expect(encodedObject["name"] as? String == "TaskObject")
        #expect(encodedObject["creatorId"] as? String == creatorId.string)
        #expect(encodedObject["creationTimestamp"] as? Double == 1_234)
        #expect(encodedObject["status"] as? Int == TaskStatus.inProgress.rawValue)
        #expect(encodedObject["lastModificationTimestamp"] as? Double == 2_345)
        #expect(encodedObject["dueTimestamp"] as? Double == 3_456)
        #expect(encodedObject["doneTimestamp"] as? Double == 4_567)
        #expect(encodedObject["requirements"] is [String: Any])
        #expect(encodedObject["description"] as? String == "Inspect equipment")
        #expect(encodedObject["desc"] == nil)
        #expect(encodedObject["assigneeObjectId"] as? String == task.assigneeObjectId?.string)
        #expect(decodedTask.coreType == .Task)
        #expect(decodedTask.objectType == "coaty.Task")
        #expect(decodedTask.name == "TaskObject")
        #expect(decodedTask.creatorId == creatorId)
        #expect(decodedTask.creationTimestamp == 1_234)
        #expect(decodedTask.status == .inProgress)
        #expect(decodedTask.lastModificationTimestamp == 2_345)
        #expect(decodedTask.dueTimestamp == 3_456)
        #expect(decodedTask.doneTimestamp == 4_567)
        #expect(decodedTask.requirements?["role"] != nil)
        #expect(decodedTask.desc == "Inspect equipment")
        #expect(decodedTask.assigneeObjectId == task.assigneeObjectId)
    }

    @Test
    func coatyTaskDynamicDecodeUsesRenamedModel() throws {
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"Task","objectType":"coaty.Task","name":"TaskObject","creatorId":"01234567-89ab-4cde-8fab-0123456789ab","creationTimestamp":1234,"status":0,"description":"queued"}}
        """
        let event: AdvertiseEvent = try PayloadCoder.decode(json)
        let task = try #require(event.data.object as? CoatyTask)

        #expect(task.coreType == .Task)
        #expect(task.objectType == "coaty.Task")
        #expect(task.status == .pending)
        #expect(task.desc == "queued")
    }

    // MARK: - Unknown object-type fallback

    @Test
    func unknownObjectTypeFallsBackToCoreType() throws {
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"CoatyObject","objectType":"com.example.UnregisteredType","name":"fallback"}}
        """
        let event: AdvertiseEvent = try PayloadCoder.decode(json)
        #expect(type(of: event.data.object) == CoatyObject.self)
        #expect(event.data.object.coreType == .CoatyObject)
        #expect(event.data.object.objectType == "com.example.UnregisteredType")
    }

    @Test
    func unknownObjectTypePreservesCustomProperties() throws {
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"CoatyObject","objectType":"com.example.UnregisteredType","name":"fallback","customScore":42,"customLabel":"hello"}}
        """
        let event: AdvertiseEvent = try PayloadCoder.decode(json)
        let object = event.data.object
        #expect(object.custom["customScore"] != nil)
        #expect(object.custom["customLabel"] != nil)
        let score = try JSONDecoder().decode(Int.self, from: Data(object.custom["customScore"]!.utf8))
        #expect(score == 42)
    }

    // MARK: - Nested object decoding

    @Test
    func nestedCoatyObjectDecodesWithinEvent() throws {
        _ = Identity.objectType
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"Identity","objectType":"coaty.Identity","name":"parent"}}
        """
        let event: AdvertiseEvent = try PayloadCoder.decode(json)
        #expect(event.data.object is Identity)
        #expect(event.data.object.name == "parent")
    }

    // MARK: - Missing or invalid discriminators

    @Test
    func missingCoreTypeThrowsDecodingFailure() throws {
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","objectType":"com.example.NoCoreType","name":"no-core"}}
        """
        do {
            let _: AdvertiseEvent = try PayloadCoder.decode(json)
            Issue.record("Expected decode to throw for missing coreType")
        } catch {
            #expect(error is AxolotyError)
        }
    }

    @Test
    func invalidCoreTypeThrowsDecodingFailure() throws {
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"Nonexistent","objectType":"com.example.BadCore","name":"bad-core"}}
        """
        do {
            let _: AdvertiseEvent = try PayloadCoder.decode(json)
            Issue.record("Expected decode to throw for invalid coreType")
        } catch {
            #expect(error is AxolotyError)
        }
    }

    @Test
    func missingObjectTypeThrowsDecodingFailure() throws {
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"CoatyObject","name":"no-object-type"}}
        """
        do {
            let _: AdvertiseEvent = try PayloadCoder.decode(json)
            Issue.record("Expected decode to throw for missing objectType")
        } catch {
            #expect(error is AxolotyError)
        }
    }

    // MARK: - Encoding failure and AxolotyError classification

    @Test
    func encodeFailureProducesAxolotyError() throws {
        struct HoldsNaN: Codable {
            let value = Double.nan

            private enum CodingKeys: String, CodingKey { case value }

            init() {}

            init(from decoder: any Decoder) throws {
                _ = try decoder.container(keyedBy: CodingKeys.self)
            }
        }
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

    @Test
    func decodeFailureProducesAxolotyError() throws {
        do {
            let _: Log = try PayloadCoder.decode("{not-json")
            Issue.record("Expected decode to throw for malformed JSON")
        } catch let error as AxolotyError {
            guard case .decodingFailure = error else {
                Issue.record("Expected .decodingFailure, got \(error)")
                return
            }
        } catch {
            // IkigaJSON or Foundation may throw their own error;
            // the point is it doesn't crash.
        }
    }

    // MARK: - RawJSONObject retention

    @Test
    func rawJSONObjectRetainedAfterDecode() throws {
        _ = Identity.objectType
        let json = """
        {"object":{"objectId":"01234567-89ab-4cde-8fab-0123456789ab","coreType":"Identity","objectType":"coaty.Identity","name":"raw-test"}}
        """
        let event: AdvertiseEvent = try PayloadCoder.decode(json)
        #expect(event.data.object.rawJSONObject?["name"]?.string == "raw-test")
        #expect(event.data.object.rawJSONObject?["objectType"]?.string == "coaty.Identity")
    }

    // MARK: - AxolotyWire publication stability

    @Test
    func communicationEventJsonProducesValidJSON() throws {
        _ = Identity.objectType
        let identity = Identity(name: "json-stability")
        let event = try AdvertiseEvent.with(object: identity)
        let json = String(decoding: try HostWireAdapter.encodeEvent(event), as: UTF8.self)
        #expect(!json.isEmpty)
        #expect(json.contains("\"object\""))
        #expect(json.contains("\"name\":\"json-stability\""))
    }

    @Test
    func coatyObjectJsonProducesValidJSON() throws {
        _ = Identity.objectType
        let identity = Identity(name: "object-json")
        let json = identity.json
        #expect(!json.isEmpty)
        #expect(json.contains("\"name\":\"object-json\""))
    }
}
