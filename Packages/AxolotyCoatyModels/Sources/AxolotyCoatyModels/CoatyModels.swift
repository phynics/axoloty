// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel

/// Foundation-free first-party Coaty convenience schemas.
///
/// IO endpoint metadata and context are owned by ``AxolotyProtocol``. This
/// package retains only the envelope-only CoatyObject compatibility schema.

/// A first-party, empty-field Coaty object schema.
public struct CoatyObject: ObjectSchema, Sendable {
    /// The portable Coaty object descriptor.
    public static let schema: PortableObjectSchema<CoatyObject> = makeSchema(objectType: "coaty.CoatyObject", coreType: .coatyObject)
    /// Creates an empty Coaty object model.
    public init() {}
    /// Decodes the common envelope-only Coaty object.
    ///
    /// - Parameter fields: The borrowed decoder for object-specific fields.
    /// - Throws: This envelope-only schema does not throw while decoding its
    ///   empty field set.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) { self.init() }
    /// Encodes no schema-specific fields.
    ///
    /// - Parameter encoder: The transactional editor receiving object fields.
    /// - Throws: This envelope-only schema does not throw while encoding its
    ///   empty field set.
    public borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {}
}


private func makeSchema<Value: Sendable>(
    objectType: StaticString,
    coreType: ObjectCoreType
) -> PortableObjectSchema<Value> {
    PortableObjectSchema(
        objectType: ObjectType(objectType)!,
        coreType: coreType,
        fieldCount: 0,
        fields: InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    )
}
