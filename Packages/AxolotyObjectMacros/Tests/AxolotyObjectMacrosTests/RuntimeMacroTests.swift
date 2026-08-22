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

@Test("generated schema decodes, edits atomically, and preserves unknown fields")
func generatedSchemaRuntimeBehavior() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":21,\"unknown\":true}")
    var object = try Object<MacroReading>(decoding: bytes)
    var manual = try Object<ManualReading>(decoding: bytes)
    #expect(MacroReading.schema.objectType == ManualReading.schema.objectType)
    #expect(MacroReading.schema.coreType == ManualReading.schema.coreType)
    #expect(MacroReading.schema.fields == ManualReading.schema.fields)
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
        _ = try Object<MacroReading>(decoding: missing)
        Issue.record("missing required field should fail")
    } catch {
        #expect(error.reason == .invalidField)
    }

    let invalid = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":true}")
    do {
        _ = try Object<MacroReading>(decoding: invalid)
        Issue.record("invalid field should fail")
    } catch {
        #expect(error.reason == .invalidField)
    }

    let explicitNull = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":21,\"retries\":null}")
    do {
        _ = try Object<MacroReading>(decoding: explicitNull)
        Issue.record("explicit null should not select a default")
    } catch {
        #expect(error.reason == .invalidField)
    }
}

@Test("default-valued fields are omitted by canonical encoding")
func defaultEncodingOmitsCanonicalValue() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"com.example.MacroReading\",\"name\":\"Reading\",\"coreType\":\"CoatyObject\",\"temperature\":21,\"retries\":3}")
    var object = try Object<MacroReading>(decoding: bytes)
    try object.edit { $0.temperature = 22 }
    switch object.withFields({ fields in fields.presence(for: "retries") }) {
    case .missing: break
    default: Issue.record("canonical default was emitted")
    }
}
