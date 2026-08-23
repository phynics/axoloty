// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyCoatyModels
import AxolotyObjectModel
import AxolotyWire
import Testing

private func slice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

@Test("all first-party core schemas are valid and preserve their core values")
func firstPartySchemasValidate() throws {
    try CoatyObject.schema.validate()
    try IoSource.schema.validate()
    try IoActor.schema.validate()
    try IoContext.schema.validate()
    #expect(IoContext.schema.coreType == .ioContext)
    #expect(IoSource.schema.coreType == .ioSource)
    #expect(IoActor.schema.coreType == .ioActor)
}

@Test("IO source and actor preserve bounded routing fields")
func ioPointFieldsRoundTrip() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Temperature\",\"updateStrategy\":2,\"useRawIoValues\":false,\"updateRate\":250,\"externalRoute\":\"external/temperature\"}")
    let source = try BoundedObject<IoSource, 512, 24>(decoding: bytes)
    #expect(source.value.valueType.encodedEquals("com.example.Temperature"))
    #expect(source.value.updateStrategy == .sample)
    #expect(source.value.updateRate == 250)
    #expect(source.value.externalRoute?.encodedEquals("external/temperature") == true)
}

@Test("empty IO value types are rejected")
func ioPointRejectsEmptyValueType() throws {
    let bytes = slice("{\"objectId\":\"33333333-3333-4333-8333-333333333333\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"valueType\":\"\"}")
    do {
        _ = try BoundedObject<IoActor, 512, 24>(decoding: bytes)
        Issue.record("empty valueType was accepted")
    } catch { #expect(error.reason == .invalidField) }
}
