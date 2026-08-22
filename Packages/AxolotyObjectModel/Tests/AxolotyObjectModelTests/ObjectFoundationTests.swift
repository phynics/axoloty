// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyWire
@testable import AxolotyObjectModel

private func slice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

private struct ReservedManualSchema: ObjectSchema {
    static let schema: PortableObjectSchema<Self> = {
        var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
        fields[0] = ObjectFieldDescriptor(key: ObjectFieldKey("object\\u0049d")!, index: 0, flags: .required)
        return PortableObjectSchema(objectType: ObjectType("com.example.Reserved")!, coreType: .coatyObject, fieldCount: 1, fields: fields)
    }()
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {}
}

private struct DuplicateManualSchema: ObjectSchema {
    static let schema: PortableObjectSchema<Self> = {
        var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
        fields[0] = ObjectFieldDescriptor(key: ObjectFieldKey("value")!, index: 0, flags: .required)
        fields[1] = ObjectFieldDescriptor(key: ObjectFieldKey("va\\u006Cue")!, index: 1, flags: .optional)
        return PortableObjectSchema(objectType: ObjectType("com.example.Duplicate")!, coreType: .coatyObject, fieldCount: 2, fields: fields)
    }()
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {}
}

private struct InvalidFlagsManualSchema: ObjectSchema {
    static let schema: PortableObjectSchema<Self> = {
        var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
        fields[0] = ObjectFieldDescriptor(key: ObjectFieldKey("value")!, index: 0, flags: [])
        return PortableObjectSchema(objectType: ObjectType("com.example.Flags")!, coreType: .coatyObject, fieldCount: 1, fields: fields)
    }()
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {}
}

private struct OverflowManualSchema: ObjectSchema {
    static let schema: PortableObjectSchema<Self> = {
        PortableObjectSchema(
            objectType: ObjectType("com.example.Overflow")!, coreType: .coatyObject,
            fieldCount: 25, fields: InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
        )
    }()
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {}
}

private struct ValidManualSchema: ObjectSchema {
    static let schema: PortableObjectSchema<Self> = PortableObjectSchema(
        objectType: ObjectType("com.example.Valid")!, coreType: .coatyObject, fieldCount: 0,
        fields: InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    )
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {}
}

private struct OtherManualSchema: ObjectSchema {
    static let schema: PortableObjectSchema<Self> = PortableObjectSchema(
        objectType: ObjectType("com.example.Other")!, coreType: .coatyObject, fieldCount: 0,
        fields: InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    )
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {}
}

@Test func schemaDescriptorUsesCompactLiteralKeys() {
    // StaticString layout is toolchain-specific. Keep the evidence as a
    // relationship: a key must fit within one descriptor and the fixed table
    // must not exceed its element-stride budget.
    #expect(MemoryLayout<ObjectFieldKey>.stride <= MemoryLayout<ObjectFieldDescriptor>.stride)
    #expect(MemoryLayout<InlineArray<24, ObjectFieldDescriptor>>.stride <= 24 * MemoryLayout<ObjectFieldDescriptor>.stride)
}

@Test func manualSchemaValidationRejectsUnsafeDescriptors() {
    do { try ReservedManualSchema.schema.validate(); Issue.record("reserved key accepted") }
    catch { #expect(error == .reservedFieldKey) }
    do { try DuplicateManualSchema.schema.validate(); Issue.record("duplicate key accepted") }
    catch { #expect(error == .duplicateFieldKey) }
    do { try InvalidFlagsManualSchema.schema.validate(); Issue.record("invalid flags accepted") }
    catch { #expect(error == .invalidFlags) }
    do { try OverflowManualSchema.schema.validate(); Issue.record("field-count overflow accepted") }
    catch { #expect(error == .invalidFieldCount) }
    var registry = ObjectSchemaRegistry<1>()
    do { try registry.register(ReservedManualSchema.schema); Issue.record("registry accepted invalid schema") }
    catch { #expect(error == .invalidSchema) }
    do {
        _ = try BoundedObject<ReservedManualSchema, 512, 24>(decoding: slice("{}"))
        Issue.record("typed object accepted invalid schema")
    } catch {
        #expect(error.reason == .invalidSchema)
    }
}

@Test func registryUseIsIdempotentAndSaturationIsAtomic() throws {
    var registry = ObjectSchemaRegistry<1>()
    try registry.use(ValidManualSchema.self)
    try registry.use(ValidManualSchema.self)
    let sealed = registry.sealed()
    #expect(sealed.count == 1)
    #expect(sealed.descriptor(for: ObjectType("com.example.Valid")!) != nil)

    var saturated = ObjectSchemaRegistry<1>()
    try saturated.use(ValidManualSchema.self)
    do { try saturated.use(OtherManualSchema.self); Issue.record("saturation accepted") }
    catch { #expect(error == .capacityExceeded) }
    let unchanged = saturated.sealed()
    #expect(unchanged.count == 1)
    #expect(unchanged.contains(ObjectType("com.example.Valid")!))
    #expect(!unchanged.contains(ObjectType("com.example.Other")!))
}

@Test func publicObjectVocabularyRetainsExplicitBoundedForms() {
    let _: Object<ValidManualSchema>.Type = Object<ValidManualSchema>.self
    let _: DynamicObject.Type = DynamicObject.self
    let _: BoundedObject<ValidManualSchema, 256, 8>.Type = BoundedObject<ValidManualSchema, 256, 8>.self
}

@Test func dynamicObjectReadsBorrowedFields() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.Reading\",\"temperature\":21.50,\"unknown\":1e2}")
    let object = try BoundedDynamicObject<512, 8>(decoding: bytes)

    object.withFields { fields in
        _ = fields.withValue(for: "temperature") { value in
            _ = value.withNumber { number in
                let matches = number.lexemeEquals("21.50")
                #expect(matches)
            }
        }
        _ = fields.withValue(for: "unknown") { value in
            let matches = value.rawEquals("1e2")
            #expect(matches)
        }
    }
}

@Test func numberViewConvertsWithoutChangingLexeme() throws {
    let bytes = slice("{\"n\":-12.50}")
    let object = try BoundedDynamicObject<128, 4>(decoding: bytes)
    object.withFields { fields in
        _ = fields.withValue(for: "n") { value in
            _ = value.withNumber { number in
                let matches = number.lexemeEquals("-12.50")
                let integer = number.intValue
                let double = number.doubleValue
                #expect(matches)
                #expect(integer == nil)
                #expect(double == -12.5)
            }
        }
    }
}

@Test func editCommitsSetNullAndRemove() throws {
    let bytes = slice("{\"a\":1,\"b\":2}")
    var object = try BoundedDynamicObject<128, 4>(decoding: bytes)
    try object.edit { editor in
        try editor.set("a", to: .number("3.00"))
        try editor.setNull("b")
        try editor.remove("missing")
    }
    let matches = object.encodedEquals("{\"a\":3.00,\"b\":null}")
    #expect(matches)
}

@Test func failedEditLeavesBytesUnchanged() throws {
    let bytes = slice("{\"a\":1}")
    var object = try BoundedDynamicObject<32, 2>(decoding: bytes)
    #expect(throws: ObjectError.self) {
        try object.edit { editor in
            try editor.setRaw("tooLong", value: slice("123456789012345678901234567890"))
        }
    }
    let matches = object.encodedEquals("{\"a\":1}")
    #expect(matches)
}

@Test func envelopeDecodesPortableIdentity() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.Reading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"externalId\":\"external\",\"parentObjectId\":\"44444444-4444-4444-8444-444444444444\",\"locationId\":\"55555555-5555-4555-8555-555555555555\",\"isDeactivated\":true}")
    let envelope = try ObjectEnvelope<64, 128>(decoding: bytes)
    #expect(envelope.objectType == ObjectType("com.example.Reading"))
    #expect(envelope.coreType == .coatyObject)
    #expect(envelope.name == BoundedEncodedText<64>("Reading"))
    #expect(envelope.externalID == BoundedEncodedText<128>("external"))
    #expect(envelope.parentObjectID == ObjectID(bytes: slice("44444444-4444-4444-8444-444444444444")))
    #expect(envelope.locationID == ObjectID(bytes: slice("55555555-5555-4555-8555-555555555555")))
    #expect(envelope.isDeactivated)
}

@Test func envelopeCapacityIsChosenByEnvelopeTypeAndKeepsEscapesEncoded() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"Reading\",\"name\":\"line\\n\",\"coreType\":\"VendorCore\",\"externalId\":\"ext\"}")
    let envelope = try ObjectEnvelope<8, 8>(decoding: bytes)
    #expect(envelope.name.length == 6)
    #expect(envelope.externalID?.length == 3)
    #expect(envelope.coreType == .unknown(ObjectType("VendorCore")!))
}

@Test func boundedEncodedTextWritesWithoutBorrowEscape() throws {
    let value = BoundedEncodedText<16>("line\\n")!
    let matches = value.encodedEquals("line\\n")
    #expect(matches)
    var output = InlineArray<64, UInt8>(repeating: 0)
    let count = withUnsafeMutableBytes(of: &output) { buffer -> Int in
        var writer = WireWriter(buffer: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity: 64)
        try? value.writeEncodedStringField("name", to: &writer)
        return writer.position
    }
    #expect(count == 15)
}

@Test func nestedMixedValuesAndEscapedKeysUseWireTokenizer() throws {
    let bytes = slice("{\"\\u0061\":{\"items\":[{\"ok\":true}]}}")
    let object = try BoundedDynamicObject<256, 4>(decoding: bytes)
    object.withFields { fields in
        _ = fields.withValue(for: "a") { value in
            let kind = value.kind
            #expect(kind == .object)
            let matches = value.rawEquals("{\"items\":[{\"ok\":true}]}")
            #expect(matches)
        }
    }
}

@Test func escapedEquivalentDuplicateKeyIsRejected() {
    #expect(throws: ObjectError.self) {
        _ = try BoundedDynamicObject<128, 4>(decoding: slice("{\"a\":1,\"\\u0061\":2}"))
    }
}

@Test func ownedSnapshotSurvivesObjectEdit() throws {
    let bytes = slice("{\"value\":1}")
    var object = try BoundedDynamicObject<128, 4>(decoding: bytes)
    var snapshot: OwnedJSONValue<32>?
    var snapshotError: ObjectError?
    object.withFields { fields in
        do throws(ObjectError) {
            snapshot = try fields.snapshot(for: "value")
        } catch {
            snapshotError = error
        }
    }
    if let snapshotError { throw snapshotError }
    let retainedSnapshot = snapshot!
    try object.edit { try $0.set("value", to: .number("2")) }
    let matches = retainedSnapshot.encodedEquals("1")
    #expect(matches)
}

@Test func snapshotMissingKeyReturnsNil() throws {
    let object = try BoundedDynamicObject<64, 2>(decoding: slice("{\"value\":1}"))
    var snapshot: OwnedJSONValue<8>?
    var snapshotError: ObjectError?
    object.withFields { fields in
        do throws(ObjectError) {
            snapshot = try fields.snapshot(for: "missing")
        } catch {
            snapshotError = error
        }
    }
    #expect(snapshotError == nil)
    #expect(snapshot == nil)
}

@Test func snapshotOverflowIsStructuredFailure() throws {
    let object = try BoundedDynamicObject<64, 2>(decoding: slice("{\"value\":12345}"))
    var snapshotError: ObjectError?
    object.withFields { fields in
        do throws(ObjectError) {
            let _: OwnedJSONValue<2>? = try fields.snapshot(for: "value")
        } catch {
            snapshotError = error
        }
    }
    #expect(snapshotError?.reason == .capacityExceeded)
}

@Test func fieldCapacityFailureLeavesObjectUnchanged() throws {
    var object = try BoundedDynamicObject<128, 1>(decoding: slice("{\"a\":1}"))
    #expect(throws: ObjectError.self) {
        try object.edit { try $0.set("b", to: .number("2")) }
    }
    let matches = object.encodedEquals("{\"a\":1}")
    #expect(matches)
}

@Test func numberConversionsCheckGrammarOverflowAndFiniteRange() {
    let tooLarge = JSONNumberView(lexeme: slice("9223372036854775808"))
    let tooLargeInt = tooLarge.intValue
    let tooLargeUInt = tooLarge.uintValue
    #expect(tooLargeInt == nil)
    #expect(tooLargeUInt == 9223372036854775808)
    let invalid = JSONNumberView(lexeme: slice("01"))
    let invalidInt = invalid.intValue
    let invalidDouble = invalid.doubleValue
    #expect(invalidInt == nil)
    #expect(invalidDouble == nil)
    let nonFinite = JSONNumberView(lexeme: slice("1e309"))
    let nonFiniteDouble = nonFinite.doubleValue
    #expect(nonFiniteDouble == nil)
}

@Test func wireFieldIndexOverflowIsStructured() {
    let bytes = slice("{\"a0\":0,\"a1\":1,\"a2\":2,\"a3\":3,\"a4\":4,\"a5\":5,\"a6\":6,\"a7\":7,\"a8\":8,\"a9\":9,\"a10\":10,\"a11\":11,\"a12\":12,\"a13\":13,\"a14\":14,\"a15\":15,\"a16\":16,\"a17\":17,\"a18\":18,\"a19\":19,\"a20\":20,\"a21\":21,\"a22\":22,\"a23\":23,\"a24\":24}")
    do throws(ObjectError) {
        _ = try BoundedDynamicObject<512, 64>(decoding: bytes)
        Issue.record("expected field-index overflow")
    } catch {
        #expect(error.reason == .fieldIndexOverflow)
    }
}

@Test func oversizedUnknownCoreFailsWithoutSubstitution() {
    // The bounded object-type storage rejects a raw unknown core beyond its documented capacity.
    #expect(ObjectCoreType(bytes: slice("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")) == nil)
}

@Test func unknownCoreRetainsBoundedRawValue() {
    #expect(ObjectCoreType(bytes: slice("VendorCore")) == .unknown(ObjectType("VendorCore")!))
}

@Test func unsafeEditKeyIsRejectedBeforeMutation() throws {
    var object = try BoundedDynamicObject<64, 2>(decoding: slice("{\"a\":1}"))
    #expect(throws: ObjectError.self) {
        try object.edit { try $0.set("bad\"key", to: .null) }
    }
    let matches = object.encodedEquals("{\"a\":1}")
    #expect(matches)
}
