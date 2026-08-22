// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyObjectMacros
import AxolotyWire
import Testing

private func slice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

@AxolotyObject(objectType: "com.example.MacroReading")
public struct MacroReading {
    public var temperature: Int
    @WireName("alarmCodes") public var alarms: Int?
    @Default(3) public var retries: Int
    public var state: Presence<Bool>
}

public struct ManualReading: ObjectSchema {
    public var temperature: Int
    public var alarms: Int?
    public var retries: Int
    public var state: Presence<Bool>

    public static let schema: PortableObjectSchema<ManualReading> = {
        var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
        fields[0] = ObjectFieldDescriptor(key: ObjectFieldKey("temperature")!, index: 0, flags: .required)
        fields[1] = ObjectFieldDescriptor(key: ObjectFieldKey("alarmCodes")!, index: 1, flags: .optional)
        fields[2] = ObjectFieldDescriptor(key: ObjectFieldKey("retries")!, index: 2, flags: [.required, .defaulted])
        fields[3] = ObjectFieldDescriptor(key: ObjectFieldKey("state")!, index: 3, flags: [.required, .presence])
        return PortableObjectSchema(
            objectType: ObjectType("com.example.MacroReading")!, coreType: .coatyObject,
            fieldCount: 4, fields: fields
        )
    }()

    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        self.temperature = try fields.decode("temperature", as: Int.self)
        self.alarms = try fields.decodeIfPresent("alarmCodes", as: Int.self)
        self.retries = try fields.decodeWithDefault("retries", as: Int.self, default: 3)
        self.state = try fields.presence("state", as: Bool.self)
    }

    public borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {
        try encoder.encode(temperature, forKey: "temperature")
        try encoder.encode(alarms, forKey: "alarmCodes")
        try encoder.encodeDefault(retries, default: 3, forKey: "retries")
        try encoder.encode(state, forKey: "state")
    }
}

@AxolotyObject(objectType: "com.example.NumericReading")
public struct NumericReading {
    @Default(7) public var count: UInt64
}

@Test("generated schema decodes, edits atomically, and preserves unknown fields")
func generatedSchemaRuntimeBehavior() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":21,\"unknown\":true}")
    var object = try BoundedObject<MacroReading, 512, 24>(decoding: bytes)
    var manual = try BoundedObject<ManualReading, 512, 24>(decoding: bytes)
    #expect(MacroReading.schema.objectType == ManualReading.schema.objectType)
    #expect(MacroReading.schema.coreType == ManualReading.schema.coreType)
    #expect(MacroReading.schema.fieldCount == ManualReading.schema.fieldCount)
    for index in 0..<Int(MacroReading.schema.fieldCount) {
        #expect(MacroReading.schema.fields[index] == ManualReading.schema.fields[index])
    }
    #expect(object.temperature == 21)
    #expect(object.alarms == nil)
    #expect(object.retries == 3)
    switch object.value.state {
    case .missing: break
    default: Issue.record("presence field did not preserve omission")
    }
    try object.edit { $0.temperature = 22 }
    try manual.edit { $0.temperature = 22 }
    #expect(object.temperature == 22)
    #expect(manual.temperature == object.temperature)
    let unknown = object.withFields { fields in fields.presence(for: "unknown") }
    switch unknown {
    case .value(let kind): #expect(kind == .trueValue)
    default: Issue.record("unknown field was not preserved")
    }
}

@Test("typed schema maps missing and invalid fields to structured object errors")
func typedSchemaErrorMapping() {
    let missing = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\"}")
    do {
        _ = try BoundedObject<MacroReading, 512, 24>(decoding: missing)
        Issue.record("missing required field should fail")
    } catch {
        #expect(error.reason == .invalidField)
    }

    let invalid = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":true}")
    do {
        _ = try BoundedObject<MacroReading, 512, 24>(decoding: invalid)
        Issue.record("invalid field should fail")
    } catch {
        #expect(error.reason == .invalidField)
    }

    let explicitNull = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":21,\"retries\":null}")
    do {
        _ = try BoundedObject<MacroReading, 512, 24>(decoding: explicitNull)
        Issue.record("explicit null should not select a default")
    } catch {
        #expect(error.reason == .invalidField)
    }
}

@Test("default-valued fields are omitted by canonical encoding")
func defaultEncodingOmitsCanonicalValue() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":21,\"retries\":3}")
    var object = try BoundedObject<MacroReading, 512, 24>(decoding: bytes)
    try object.edit { $0.temperature = 22 }
    switch object.withFields({ fields in fields.presence(for: "retries") }) {
    case .missing: break
    default: Issue.record("canonical default was emitted")
    }
}

@Test("numeric codecs and typed-use registration preserve bounded behavior")
func numericCodecsAndTypedRegistration() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.NumericReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"count\":9}")
    var registry = ObjectSchemaRegistry<1>()
    let object = try BoundedObject<NumericReading, 512, 24>(decoding: bytes, using: &registry)
    #expect(object.count == 9)
    #expect(registry.sealed().contains(NumericReading.schema.objectType))
}

@Test("typed-use registration saturation leaves the registry unchanged")
func typedRegistrationSaturationIsAtomic() throws {
    let numericBytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.NumericReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"count\":9}")
    let macroBytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":21}")
    var registry = ObjectSchemaRegistry<1>()
    _ = try BoundedObject<NumericReading, 512, 24>(decoding: numericBytes, using: &registry)
    do {
        _ = try BoundedObject<MacroReading, 512, 24>(decoding: macroBytes, using: &registry)
        Issue.record("saturated typed registration succeeded")
    } catch { #expect(error.reason == .capacityExceeded) }
    let sealed = registry.sealed()
    #expect(sealed.count == 1)
    #expect(!sealed.contains(MacroReading.schema.objectType))
}

@Test("typed identity validation does not impose a hidden name capacity")
func typedIdentityAllowsLongName() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\",\"coreType\":\"CoatyObject\",\"temperature\":21}")
    let object = try BoundedObject<MacroReading, 512, 24>(decoding: bytes)
    #expect(object.temperature == 21)
}

@Test("typed identity validation rejects missing or malformed metadata")
func typedIdentityRejectsInvalidMetadata() {
    let missingName = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"coreType\":\"CoatyObject\",\"temperature\":21}")
    do {
        _ = try BoundedObject<MacroReading, 512, 24>(decoding: missingName)
        Issue.record("missing name was accepted")
    } catch { #expect(error.reason == .invalidEnvelope) }

    let invalidParent = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"parentObjectId\":true,\"temperature\":21}")
    do {
        _ = try BoundedObject<MacroReading, 512, 24>(decoding: invalidParent)
        Issue.record("invalid parentObjectId was accepted")
    } catch { #expect(error.reason == .invalidEnvelope) }
}
