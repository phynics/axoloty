// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel

/// Foundation-free first-party Coaty schemas for the portable G3 boundary.
///
/// This package currently carries the envelope-only ``CoatyObject`` and
/// ``IoContext`` plus complete bounded ``IoSource`` and ``IoActor`` routing
/// models. Nested/list-bearing core models remain a later migration until
/// their bounded value representation is specified.

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

/// The bounded backpressure strategies used by an ``IoSource``.
public enum IoSourceBackpressureStrategy: Int, Sendable, Equatable {
    /// Selects `none` when no update rate is supplied, otherwise `sample`.
    case `default`
    /// Publishes every value immediately.
    case none
    /// Publishes the latest value at the recommended rate.
    case sample
    /// Publishes only after the recommended interval has elapsed.
    case throttle
}

extension IoSourceBackpressureStrategy: ObjectFieldDecodable, ObjectFieldEncodable {
    /// Decodes the wire integer strategy value.
    ///
    /// - Parameter value: The borrowed JSON integer.
    /// - Returns: The matching backpressure strategy.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value is not a
    ///   supported strategy integer.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        guard let raw = try? Int.decode(from: value), let strategy = Self(rawValue: raw) else { throw .invalidField }
        return strategy
    }

    /// Encodes the strategy's stable wire integer value.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the strategy.
    ///   - key: The bounded wire key for the strategy.
    /// - Throws: ``ObjectEncodingError`` when the editor rejects the integer.
    public func encode<let editorCapacity: Int>(to editor: inout ObjectFieldEncoder<editorCapacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        try rawValue.encode(to: &editor, forKey: key)
    }
}

/// A first-party IoSource schema with all bounded routing fields.
public struct IoSource: ObjectSchema, Sendable {
    /// The semantic application value type.
    public var valueType: BoundedEncodedText<128>
    /// The source backpressure strategy.
    public var updateStrategy: IoSourceBackpressureStrategy?
    /// Whether values are transported as raw bytes.
    public var useRawIoValues: Bool?
    /// The recommended update interval in milliseconds.
    public var updateRate: Int?
    /// An optional route supplied by an external binding.
    public var externalRoute: BoundedEncodedText<128>?

    /// The portable IoSource descriptor.
    public static let schema: PortableObjectSchema<IoSource> = makeSchema(
        objectType: "coaty.IoSource", coreType: .ioSource,
        field0: ("valueType", .required), field1: ("updateStrategy", .optional), field2: ("useRawIoValues", .optional),
        field3: ("updateRate", .optional), field4: ("externalRoute", .optional)
    )

    /// Creates a bounded IoSource model.
    ///
    /// - Parameters:
    ///   - valueType: The required non-empty semantic value type.
    ///   - updateStrategy: The optional source backpressure strategy.
    ///   - useRawIoValues: Whether values use raw-byte transport.
    ///   - updateRate: The optional recommended update interval.
    ///   - externalRoute: The optional external binding route.
    /// - Throws: ``ObjectError/invalidField`` when `valueType` is empty.
    public init(
        valueType: BoundedEncodedText<128>,
        updateStrategy: IoSourceBackpressureStrategy? = nil,
        useRawIoValues: Bool? = false,
        updateRate: Int? = nil,
        externalRoute: BoundedEncodedText<128>? = nil
    ) throws(ObjectError) {
        guard valueType.length > 0 else { throw ObjectError(.invalidField) }
        self.valueType = valueType; self.updateStrategy = updateStrategy; self.useRawIoValues = useRawIoValues
        self.updateRate = updateRate; self.externalRoute = externalRoute
    }

    /// Decodes all IoSource fields from a borrowed object view.
    ///
    /// - Parameter fields: The borrowed decoder for the source fields.
    /// - Throws: ``ObjectDecodingError`` when a required or optional field is
    ///   absent, malformed, or outside its bounded representation.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        let valueType = try fields.decode("valueType", as: BoundedEncodedText<128>.self)
        guard valueType.length > 0 else { throw .invalidField }
        self.valueType = valueType
        self.updateStrategy = try fields.decodeIfPresent("updateStrategy", as: IoSourceBackpressureStrategy.self)
        self.useRawIoValues = try fields.decodeIfPresent("useRawIoValues", as: Bool.self)
        self.updateRate = try fields.decodeIfPresent("updateRate", as: Int.self)
        self.externalRoute = try fields.decodeIfPresent("externalRoute", as: BoundedEncodedText<128>.self)
    }

    /// Encodes all IoSource fields into a transactional editor.
    ///
    /// - Parameter encoder: The transactional editor receiving source fields.
    /// - Throws: ``ObjectEncodingError`` when a field cannot be represented or
    ///   the editor has insufficient capacity.
    public borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {
        try encoder.encode(valueType, forKey: "valueType"); try encoder.encode(updateStrategy, forKey: "updateStrategy")
        try encoder.encode(useRawIoValues, forKey: "useRawIoValues"); try encoder.encode(updateRate, forKey: "updateRate")
        try encoder.encode(externalRoute, forKey: "externalRoute")
    }
}

/// A first-party IoActor schema with all bounded routing fields.
public struct IoActor: ObjectSchema, Sendable {
    /// The semantic application value type.
    public var valueType: BoundedEncodedText<128>
    /// Whether values are transported as raw bytes.
    public var useRawIoValues: Bool?
    /// The recommended update interval in milliseconds.
    public var updateRate: Int?
    /// An optional route supplied by an external binding.
    public var externalRoute: BoundedEncodedText<128>?

    /// The portable IoActor descriptor.
    public static let schema: PortableObjectSchema<IoActor> = makeSchema(
        objectType: "coaty.IoActor", coreType: .ioActor,
        field0: ("valueType", .required), field1: ("useRawIoValues", .optional), field2: ("updateRate", .optional), field3: ("externalRoute", .optional)
    )

    /// Creates a bounded IoActor model.
    ///
    /// - Parameters:
    ///   - valueType: The required non-empty semantic value type.
    ///   - useRawIoValues: Whether values use raw-byte transport.
    ///   - updateRate: The optional recommended update interval.
    ///   - externalRoute: The optional external binding route.
    /// - Throws: ``ObjectError/invalidField`` when `valueType` is empty.
    public init(
        valueType: BoundedEncodedText<128>, useRawIoValues: Bool? = false, updateRate: Int? = nil,
        externalRoute: BoundedEncodedText<128>? = nil
    ) throws(ObjectError) {
        guard valueType.length > 0 else { throw ObjectError(.invalidField) }
        self.valueType = valueType; self.useRawIoValues = useRawIoValues; self.updateRate = updateRate; self.externalRoute = externalRoute
    }

    /// Decodes all IoActor fields from a borrowed object view.
    ///
    /// - Parameter fields: The borrowed decoder for the actor fields.
    /// - Throws: ``ObjectDecodingError`` when a required or optional field is
    ///   absent, malformed, or outside its bounded representation.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        let valueType = try fields.decode("valueType", as: BoundedEncodedText<128>.self)
        guard valueType.length > 0 else { throw .invalidField }
        self.valueType = valueType
        self.useRawIoValues = try fields.decodeIfPresent("useRawIoValues", as: Bool.self)
        self.updateRate = try fields.decodeIfPresent("updateRate", as: Int.self)
        self.externalRoute = try fields.decodeIfPresent("externalRoute", as: BoundedEncodedText<128>.self)
    }

    /// Encodes all IoActor fields into a transactional editor.
    ///
    /// - Parameter encoder: The transactional editor receiving actor fields.
    /// - Throws: ``ObjectEncodingError`` when a field cannot be represented or
    ///   the editor has insufficient capacity.
    public borrowing func encodeFields<let editorCapacity: Int>(to encoder: inout ObjectFieldEncoder<editorCapacity>) throws(ObjectEncodingError) {
        try encoder.encode(valueType, forKey: "valueType"); try encoder.encode(useRawIoValues, forKey: "useRawIoValues")
        try encoder.encode(updateRate, forKey: "updateRate"); try encoder.encode(externalRoute, forKey: "externalRoute")
    }
}

/// A first-party IoContext schema.
public struct IoContext: ObjectSchema, Sendable {
    /// The portable IoContext descriptor.
    public static let schema: PortableObjectSchema<IoContext> = makeSchema(objectType: "coaty.IoContext", coreType: .ioContext)
    /// Creates an empty IoContext model.
    public init() {}
    /// Decodes the common envelope-only IoContext object.
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

private func makeSchema<Value: Sendable>(
    objectType: StaticString,
    coreType: ObjectCoreType,
    field0: (StaticString, ObjectFieldFlags),
    field1: (StaticString, ObjectFieldFlags),
    field2: (StaticString, ObjectFieldFlags),
    field3: (StaticString, ObjectFieldFlags),
    field4: (StaticString, ObjectFieldFlags)
) -> PortableObjectSchema<Value> {
    var descriptors = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    let first = field0; let second = field1; let third = field2; let fourth = field3; let fifth = field4
    descriptors[0] = ObjectFieldDescriptor(key: ObjectFieldKey(first.0)!, index: 0, flags: first.1)
    descriptors[1] = ObjectFieldDescriptor(key: ObjectFieldKey(second.0)!, index: 1, flags: second.1)
    descriptors[2] = ObjectFieldDescriptor(key: ObjectFieldKey(third.0)!, index: 2, flags: third.1)
    descriptors[3] = ObjectFieldDescriptor(key: ObjectFieldKey(fourth.0)!, index: 3, flags: fourth.1)
    descriptors[4] = ObjectFieldDescriptor(key: ObjectFieldKey(fifth.0)!, index: 4, flags: fifth.1)
    return PortableObjectSchema(objectType: ObjectType(objectType)!, coreType: coreType, fieldCount: 5, fields: descriptors)
}

private func makeSchema<Value: Sendable>(
    objectType: StaticString,
    coreType: ObjectCoreType,
    field0: (StaticString, ObjectFieldFlags),
    field1: (StaticString, ObjectFieldFlags),
    field2: (StaticString, ObjectFieldFlags),
    field3: (StaticString, ObjectFieldFlags)
) -> PortableObjectSchema<Value> {
    var descriptors = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    let first = field0; let second = field1; let third = field2; let fourth = field3
    descriptors[0] = ObjectFieldDescriptor(key: ObjectFieldKey(first.0)!, index: 0, flags: first.1)
    descriptors[1] = ObjectFieldDescriptor(key: ObjectFieldKey(second.0)!, index: 1, flags: second.1)
    descriptors[2] = ObjectFieldDescriptor(key: ObjectFieldKey(third.0)!, index: 2, flags: third.1)
    descriptors[3] = ObjectFieldDescriptor(key: ObjectFieldKey(fourth.0)!, index: 3, flags: fourth.1)
    return PortableObjectSchema(objectType: ObjectType(objectType)!, coreType: coreType, fieldCount: 4, fields: descriptors)
}
