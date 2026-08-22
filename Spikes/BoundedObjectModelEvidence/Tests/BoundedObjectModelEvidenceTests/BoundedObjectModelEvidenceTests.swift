// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyCoatyModels
import AxolotyWire
import Testing

private func slice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

@Test("schema registry and first-party typed object remain bounded")
func schemaAndTypedObjectEvidence() throws {
    try IoSource.schema.validate()
    var registry = ObjectSchemaRegistry<1>()
    try registry.use(IoSource.self)
    var registryRejected = false
    do throws(ObjectSchemaRegistryError) {
        try registry.use(IoActor.self)
    } catch {
        registryRejected = error == .capacityExceeded
    }
    #expect(registryRejected)
    let registryCount = registry.sealed().count
    #expect(registryCount == 1)
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"T\"}")
    let typed = try BoundedObject<IoSource, 512, 16>(decoding: bytes)
    let typedValueTypeMatches = typed.value.valueType.encodedEquals("T")
    #expect(typedValueTypeMatches)
}

@Test("predicate decode evaluation encode and canonical round trip are sanitizer-covered")
func predicateEvidence() throws {
    let predicateBytes = slice("{\"conditions\":[\"value\",[7,1]]}")
    let predicate = try ObjectPredicate<16, 16, 16, 64>(decoding: predicateBytes)
    let object = try BoundedDynamicObject<128, 4>(decoding: slice("{\"value\":1}"))
    let predicateMatches = predicate.matches(object: object)
    #expect(predicateMatches)

    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    defer { output.deallocate() }
    var writer = WireWriter(buffer: output, capacity: 128)
    try predicate.encode(to: &writer)
    let encoded = ByteSlice(bytes: output, length: writer.position)
    let encodedMatches = encoded.equals("{\"conditions\":[\"value\",[7,1]]}")
    #expect(encodedMatches)
    let decoded = try ObjectPredicate<16, 16, 16, 64>(decoding: encoded)
    let decodedMatches = decoded.matches(object: object)
    #expect(decodedMatches)
}

private func objectBytes() -> ByteSlice { slice("{\"a\":0}") }
private func envelopeBytes() -> ByteSlice {
    slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.Measurement\",\"name\":\"\",\"coreType\":\"Task\",\"externalId\":\"x\"}")
}

@Test("object-model measurement layouts are explicit")
func measurementLayouts() {
    #expect(MemoryLayout<BoundedDynamicObject<1, 1>>.size > 0)
    #expect(MemoryLayout<BoundedDynamicObject<16, 16>>.stride > MemoryLayout<BoundedDynamicObject<1, 1>>.stride)
    #expect(MemoryLayout<BoundedDynamicObject<64, 64>>.stride > MemoryLayout<BoundedDynamicObject<16, 16>>.stride)
    #expect(MemoryLayout<ObjectEnvelope<1, 1>>.size > 0)
    #expect(MemoryLayout<ObjectEnvelope<64, 64>>.stride >= MemoryLayout<ObjectEnvelope<16, 16>>.stride)
}

@Test("capacity one reports minimum-object rejection")
func capacityOneIsMeasuredWithoutClaimingAcceptance() {
    var objectRejected = false
    do throws(ObjectError) {
        _ = try BoundedDynamicObject<1, 1>(decoding: objectBytes())
    } catch {
        objectRejected = error.reason == .capacityExceeded
    }
    #expect(objectRejected)

    var envelopeRejected = false
    do throws(ObjectError) {
        _ = try ObjectEnvelope<1, 1>(decoding: envelopeBytes())
    } catch {
        envelopeRejected = error.reason == .invalidEnvelope
    }
    #expect(envelopeRejected)
}

@Test("saturation rejects and preserves object bytes")
func saturationIsAtomic() throws {
    for capacity in [16, 64] {
        if capacity == 16 {
            try saturation(BoundedDynamicObject<16, 16>.self)
        } else {
            try saturation(BoundedDynamicObject<64, 64>.self)
        }
    }
}

private func saturation<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type) throws {
    var object = try BoundedDynamicObject<capacity, capacity>(decoding: objectBytes())
    let initialBytesMatch = object.encodedEquals("{\"a\":0}")
    #expect(initialBytesMatch)
    var editRejected = false
    do throws(ObjectError) {
        try object.edit { try $0.setRaw("overflow", value: slice("999999999999999999999999999999999999999999999999999999999999999999999999999999")) }
    } catch {
        editRejected = error.reason == .capacityExceeded
    }
    #expect(editRejected)
    let unchanged = object.encodedEquals("{\"a\":0}")
    #expect(unchanged)
}

@Test("deterministic randomized edits and reads remain bounded")
func randomizedEditRead() throws {
    try randomized(BoundedDynamicObject<16, 16>.self)
    try randomized(BoundedDynamicObject<64, 64>.self)
}

private func randomized<let capacity: Int>(_: BoundedDynamicObject<capacity, capacity>.Type) throws {
    var object = try BoundedDynamicObject<capacity, capacity>(decoding: objectBytes())
    var seed: UInt64 = 0x41584f4c4f5459
    for _ in 0..<2_000 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        if seed & 1 == 0 {
            try object.edit { try $0.setNull("a") }
            var presence: Presence<JSONValueKind> = .missing
            object.withFields { fields in presence = fields.presence(for: "a") }
            if case .null = presence { #expect(true) } else { Issue.record("expected null presence") }
        } else {
            try object.edit { try $0.set("a", to: .number("1")) }
            var presence: Presence<JSONValueKind> = .missing
            object.withFields { fields in presence = fields.presence(for: "a") }
            if case .value(.number) = presence { #expect(true) } else { Issue.record("expected number presence") }
        }
    }
}
