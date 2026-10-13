// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire
import Testing
@testable import Axoloty

@Suite("Runtime generated wire payloads")
struct RuntimeWirePayloadTests {
    private let objectID = "00000000-0000-4000-8000-000000000201"
    private let sourceID = "00000000-0000-4000-8000-000000000301"

    @Test("axoloty/1 identity advertise uses canonical tag-37 CBOR")
    func identityAdvertiseCBOR() throws {
        let identity = try RuntimeIdentity(id: try #require(UUID16(parsing: objectID)), name: "runtime")
        let payload = try RuntimeWirePayload.cborAdvertise(identity: identity)
        #expect(payload == hex(
            "a1666f626a656374a4646e616d656772756e74696d6568636f726554797065684964656e74697479"
                + "686f626a6563744964d8255000000000000040008000000000000201"
                + "6a6f626a656374547970656e636f6174792e4964656e74697479"
        ))
    }

    @Test("axoloty/1 deadvertise uses canonical tag-37 CBOR")
    func deadvertiseCBOR() throws {
        let identity = try RuntimeIdentity(id: try #require(UUID16(parsing: objectID)), name: "runtime")
        let viaIdentity = try RuntimeLifecyclePayload.deadvertise(identity, profile: .axoloty1CBOR)
        let viaObject = try RuntimeLifecyclePayload.deadvertise(
            objectID: ObjectID(uuid: try #require(UUID16(parsing: objectID))),
            profile: .axoloty1CBOR
        )
        let expected = hex("a1696f626a65637449647381d8255000000000000040008000000000000201")
        #expect(viaIdentity == expected)
        #expect(viaObject == expected)
    }

    @Test("coaty/3 identity advertise stays byte-identical")
    func identityAdvertiseJSON() throws {
        let identity = try RuntimeIdentity(id: try #require(UUID16(parsing: objectID)), name: "runtime")
        let payload = try RuntimeLifecyclePayload.advertise(identity, profile: .coaty3JSON)
        let expected = "{\"object\":{\"coreType\":\"Identity\",\"name\":\"runtime\","
            + "\"objectId\":\"\(objectID)\",\"objectType\":\"coaty.Identity\"}}"
        #expect(payload == Array(expected.utf8))
    }

    @Test("coaty/3 deadvertise stays byte-identical")
    func deadvertiseJSON() throws {
        let deadvertise = try RuntimeLifecyclePayload.deadvertise(
            objectID: ObjectID(uuid: try #require(UUID16(parsing: objectID))),
            profile: .coaty3JSON
        )
        #expect(deadvertise == Array("{\"objectIds\":[\"\(objectID)\"]}".utf8))
    }

    @Test("axoloty/1 IO endpoint advertise rebuilds schema fields and decodes escapes")
    func ioEndpointAdvertiseCBOR() throws {
        let stored = try boundedJSON(
            "{\"objectId\":\"\(sourceID)\",\"objectType\":\"coaty.IoSource\","
                + "\"name\":\"so\\u0075rce\",\"coreType\":\"IoSource\","
                + "\"valueType\":\"com.example.Bool\",\"updateStrategy\":1,"
                + "\"useRawIoValues\":true}"
        )
        let object = try RuntimeWirePayload.cborIoEndpointObject(storedJSON: stored)
        let payload = try RuntimeWirePayload.advertiseEnvelope(object: object, profile: .axoloty1CBOR)
        #expect(payload == hex(
            "a1666f626a656374a7646e616d6566736f7572636568636f72655479706568496f536f75726365"
                + "686f626a6563744964d8255000000000000040008000000000000301"
                + "6976616c75655479706570636f6d2e6578616d706c652e426f6f6c"
                + "6a6f626a656374547970656e636f6174792e496f536f75726365"
                + "6e7570646174655374726174656779016e757365526177496f56616c756573f5"
        ))
    }

    @Test("coaty/3 IO endpoint advertise keeps the raw stored object bytes")
    func ioEndpointAdvertiseJSON() throws {
        let raw = "{\"objectId\":\"\(sourceID)\",\"objectType\":\"coaty.IoSource\","
            + "\"name\":\"source\",\"coreType\":\"IoSource\","
            + "\"valueType\":\"com.example.Bool\"}"
        let payload = try RuntimeWirePayload.advertiseEnvelope(
            object: Array(raw.utf8),
            profile: .coaty3JSON
        )
        #expect(payload == Array("{\"object\":\(raw)}".utf8))
    }

    @Test("axoloty/1 conformance payloads are canonical CBOR")
    func conformanceCBOR() throws {
        #expect(try RuntimeWirePayload.cborErrorObject(code: 10, message: "boom") == hex(
            "a264636f64650a676d65737361676564626f6f6d"
        ))
        #expect(try RuntimeWirePayload.emptyObject(profile: .axoloty1CBOR) == hex("a0"))
        #expect(try RuntimeWirePayload.emptyArray(profile: .axoloty1CBOR) == hex("80"))
        #expect(try RuntimeWirePayload.emptyObject(profile: .coaty3JSON) == Array("{}".utf8))
        #expect(try RuntimeWirePayload.emptyArray(profile: .coaty3JSON) == Array("[]".utf8))
    }

    @Test("axoloty/1 rejects an unknown IO metadata field")
    func unknownIOFieldRejected() throws {
        let stored = try boundedJSON(
            "{\"objectId\":\"\(sourceID)\",\"objectType\":\"coaty.IoSource\","
                + "\"name\":\"source\",\"coreType\":\"IoSource\","
                + "\"valueType\":\"com.example.Bool\",\"unexpected\":1}"
        )
        expectMalformedPayload { try RuntimeWirePayload.cborIoEndpointObject(storedJSON: stored) }
    }

    @Test("axoloty/1 rejects an integer that does not fit exactly")
    func integerOverflowRejected() throws {
        let stored = try boundedJSON(
            "{\"objectId\":\"\(sourceID)\",\"objectType\":\"coaty.IoSource\","
                + "\"name\":\"source\",\"coreType\":\"IoSource\","
                + "\"valueType\":\"com.example.Bool\",\"updateRate\":9223372036854775808}"
        )
        expectMalformedPayload { try RuntimeWirePayload.cborIoEndpointObject(storedJSON: stored) }
    }

    @Test("axoloty/1 rejects a fractional IO metadata number")
    func fractionalNumberRejected() throws {
        let stored = try boundedJSON(
            "{\"objectId\":\"\(sourceID)\",\"objectType\":\"coaty.IoSource\","
                + "\"name\":\"source\",\"coreType\":\"IoSource\","
                + "\"valueType\":\"com.example.Bool\",\"updateRate\":1.5}"
        )
        expectMalformedPayload { try RuntimeWirePayload.cborIoEndpointObject(storedJSON: stored) }
    }

    @Test("axoloty/1 preserves an explicit null IO metadata field")
    func explicitNullIOField() throws {
        let stored = try boundedJSON(
            "{\"objectId\":\"\(sourceID)\",\"objectType\":\"coaty.IoSource\","
                + "\"name\":\"source\",\"coreType\":\"IoSource\","
                + "\"valueType\":\"com.example.Bool\",\"externalRoute\":null}"
        )
        let object = try RuntimeWirePayload.cborIoEndpointObject(storedJSON: stored)
        #expect(object.containsSubsequence(hex("6d65787465726e616c526f757465f6")))
    }

    // MARK: - Helpers

    private func expectMalformedPayload(_ body: () throws -> [UInt8]) {
        do {
            _ = try body()
            Issue.record("expected a malformed payload rejection")
        } catch let error as ProtocolError {
            #expect(error == ProtocolError(.malformedPayload))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private func boundedJSON(_ json: String) throws -> BoundedIoBytes<2048> {
        let bytes = Array(json.utf8)
        return try bytes.withUnsafeBufferPointer { buffer in
            try BoundedIoBytes(copying: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
    }

    private func hex(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, pattern.count <= count else { return false }
        for start in 0...(count - pattern.count)
        where self[start..<(start + pattern.count)].elementsEqual(pattern) {
            return true
        }
        return false
    }
}

