// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

private struct EmbeddedConstructedSchema: ObjectSchema {
    static let schema: PortableObjectSchema<Self> = PortableObjectSchema(
        objectType: ObjectType("com.example.EmbeddedConstructed")!,
        coreType: .coatyObject,
        fieldCount: 0,
        fields: InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    )

    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}

    borrowing func encodeFields<let editorCapacity: Int>(
        to encoder: inout ObjectFieldEncoder<editorCapacity>
    ) throws(ObjectEncodingError) {}

    init() {}
}

@inline(never)
func axoloty_object_model_embedded_link_probe() -> Bool {
    let idBytes: StaticString = "33333333-3333-4333-8333-333333333333"
    guard let objectID = ObjectID(bytes: ByteSlice(
        bytes: idBytes.utf8Start,
        length: idBytes.utf8CodeUnitCount
    )), let name = BoundedEncodedText<16>("Embedded") else { return false }
    guard let envelope = try? ObjectEnvelope<16, 16>(
        objectID: objectID,
        objectType: ObjectType("com.example.EmbeddedConstructed")!,
        name: name,
        coreType: .coatyObject
    ) else { return false }
    guard let object = try? Object<EmbeddedConstructedSchema>(
        envelope: envelope,
        fields: EmbeddedConstructedSchema()
    ) else { return false }
    var hasBytes = false
    object.withEncodedBytes { bytes in hasBytes = bytes.length > 0 }
    return hasBytes
}
