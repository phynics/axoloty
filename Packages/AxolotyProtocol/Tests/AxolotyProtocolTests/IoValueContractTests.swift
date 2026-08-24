// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyObjectModel
import AxolotyWire
@testable import AxolotyProtocol

@Suite("Portable IO value contracts")
struct IoValueContractTests {
    @Test("semantic value types are bounded and metadata-owned")
    func valueTypeRoundTrip() throws {
        let type = try IoValueType("com.example.temperature")
        #expect(type.equals("com.example.temperature"))
        #expect(!type.equals("com.example.other"))
    }

    @Test("dynamic values retain their fixed representation")
    func dynamicRepresentation() throws {
        let literal: StaticString = "{}"
        let bytes = ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount)
        let json = try BoundedJSONValue<512>(copying: bytes)
        let value = DynamicIoValue.json(json)
        #expect(value.representation == .json)
    }

    @Test("JSON output copies bounded payloads")
    func jsonOutput() throws {
        var output = IoJSONOutput()
        try output.write("{\"celsius\":23.4}")
        let value = output.finish()
        value.withBytes { bytes in #expect(bytes.equals("{\"celsius\":23.4}")) }
    }

    @Test("portable JSON scalars use canonical bounded encodings")
    func portableScalarRoundTrips() throws {
        try expectJSONRoundTrip(true, encoded: "true")
        try expectJSONRoundTrip(Int(-42), encoded: "-42")
        try expectJSONRoundTrip(Int64.min, encoded: "-9223372036854775808")
        try expectJSONRoundTrip(UInt64.max, encoded: "18446744073709551615")
        try expectJSONRoundTrip(Int8(-12), encoded: "-12")
        try expectJSONRoundTrip(UInt32.max, encoded: "4294967295")
    }

    @Test("dynamic handles use the endpoint value contract")
    func dynamicHandleTypesCompile() {
        let _: IoSource<DynamicIoValue>.Type = IoSource<DynamicIoValue>.self
        let _: IoActor<DynamicIoValue>.Type = IoActor<DynamicIoValue>.self
    }

    @Test("source definitions derive wire fields and preserve unknown data")
    func sourceDefinitionNormalization() throws {
        let literal: StaticString = "{\"objectId\":\"11111111-1111-4111-8111-111111111111\",\"objectType\":\"coaty.IoSource\",\"name\":\"Source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.temperature\",\"updateStrategy\":3,\"useRawIoValues\":false,\"updateRate\":99,\"externalRoute\":\"old/route\",\"vendor\":1e2}"
        let object = try Object<IoSourceMetadata>(decoding: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))
        let definition = try IoSourceEndpointDefinition(
            metadata: object,
            representation: .binary,
            publication: .latest(atMostEveryMS: 0)
        )

        #expect(definition.id == objectID("11111111-1111-4111-8111-111111111111"))
        #expect(definition.representation == .binary)
        #expect(definition.publication == .latest(atMostEveryMS: 0))
        definition.withObjectBytes { bytes in
            bytes.withBytes { pointer, length in
                let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
                #expect(reader.readInt("updateStrategy") == 2)
                #expect(reader.readBool("useRawIoValues") == true)
                #expect(reader.readInt("updateRate") == 0)
                #expect(reader.readField("externalRoute") == nil)
                #expect(reader.readField("vendor")?.equals("1e2") == true)
            }
        }
    }

    @Test("actor definitions omit JSON defaults and preserve explicit zero")
    func actorDefinitionNormalization() throws {
        let literal: StaticString = "{\"objectId\":\"22222222-2222-4222-8222-222222222222\",\"objectType\":\"coaty.IoActor\",\"name\":\"Actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.temperature\",\"useRawIoValues\":true,\"externalRoute\":\"old/route\"}"
        let object = try Object<IoActorMetadata>(decoding: ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))
        let definition = try IoActorEndpointDefinition(
            metadata: object,
            representation: .json,
            recommendedUpdateRateMS: 0
        )

        definition.withObjectBytes { bytes in
            bytes.withBytes { pointer, length in
                let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
                #expect(reader.readField("useRawIoValues") == nil)
                #expect(reader.readInt("updateRate") == 0)
                #expect(reader.readField("externalRoute") == nil)
            }
        }
    }

    @Test("publication decisions are two phase and wrapping")
    func publicationStateMachine() {
        var machine = IoPublicationStateMachine()
        let associated = IoAssociationState(
            generation: 1,
            hasAssociations: true,
            associationCount: 1,
            recommendedUpdateRateMS: 20
        )

        #expect(machine.decision(policy: .latest(atMostEveryMS: 10), association: associated, nowMS: UInt32.max - 4) == .emitCurrent)
        machine.commitEmission(at: UInt32.max - 4)
        #expect(machine.decision(policy: .latest(atMostEveryMS: 10), association: associated, nowMS: 10) == .replaceLatest)
        #expect(machine.decision(policy: .latest(atMostEveryMS: 10), association: associated, nowMS: 15) == .emitCurrent)
        #expect(machine.decision(policy: .throttle(forMS: 10), association: associated, nowMS: 10) == .throttled)
        #expect(machine.decision(policy: .immediate, association: IoAssociationState(), nowMS: 10) == .notAssociated)
        machine.clear()
        #expect(machine.decision(policy: .immediate, association: associated, nowMS: 10) == .emitCurrent)
    }
}

private func withSlice<R>(_ literal: StaticString, _ body: (ByteSlice) throws -> R) rethrows -> R {
    try body(ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount))
}

private func objectID(_ literal: StaticString) -> ObjectID {
    withSlice(literal) { ObjectID(bytes: $0)! }
}

private func expectJSONRoundTrip<Value: JSONIoValue & Equatable>(
    _ value: Value,
    encoded: StaticString
) throws {
    try value.withEncodedIoPayload(representation: .json) { bytes in
        #expect(bytes.equals(encoded))
        let decoded = try Value.decodeIoPayload(bytes, representation: .json)
        #expect(decoded == value)
    }
}
