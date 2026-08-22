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
        self.retries = try fields.decodeIfPresent("retries", as: Int.self) ?? 3
        self.state = try fields.presence("state", as: Bool.self)
    }

    public borrowing func encodeFields<let capacity: Int>(to encoder: inout ObjectFieldEncoder<capacity>) throws(ObjectEncodingError) {
        try encoder.encode(temperature, forKey: "temperature")
        try encoder.encode(alarms, forKey: "alarmCodes")
        try encoder.encode(retries, forKey: "retries")
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
