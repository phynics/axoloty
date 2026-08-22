// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A wire field declared by a portable object schema.
///
/// Descriptors are deliberately small and contain no reflection metadata. The
/// macro and a hand-written conformance both create the same descriptor value,
/// which keeps the generated and Embedded Swift paths interchangeable.
public struct ObjectFieldDescriptor: Sendable {
    /// A descriptor representing an unused slot in a fixed schema table.
    public static let empty = ObjectFieldDescriptor(
        sourceName: "",
        wireName: "",
        index: 0,
        isOptional: false,
        hasDefault: false
    )

    /// The Swift source property name.
    public let sourceName: String
    /// The name used on the wire.
    public let wireName: String
    /// Stable source-order index of this field.
    public let index: Int
    /// Whether omission is valid for this field.
    public let isOptional: Bool
    /// Whether the schema supplies a value when the field is omitted.
    public let hasDefault: Bool

    /// Creates a field descriptor.
    public init(
        sourceName: String,
        wireName: String,
        index: Int,
        isOptional: Bool,
        hasDefault: Bool
    ) {
        self.sourceName = sourceName
        self.wireName = wireName
        self.index = index
        self.isOptional = isOptional
        self.hasDefault = hasDefault
    }

    /// Whether two descriptors contain the same wire contract.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceName == rhs.sourceName &&
            lhs.wireName == rhs.wireName &&
            lhs.index == rhs.index &&
            lhs.isOptional == rhs.isOptional &&
            lhs.hasDefault == rhs.hasDefault
    }
}

extension ObjectFieldDescriptor: Equatable {}

/// The immutable, generated-or-manual description of one object schema.
///
/// The descriptor table is fixed at 64 entries. A schema with fewer fields
/// leaves the remaining entries as ``ObjectFieldDescriptor/empty``. This is a
/// compile-time upper bound, not a request to allocate a growable collection.
public struct PortableObjectSchema<Value>: Sendable where Value: Sendable {
    /// Maximum number of fields in one portable schema.
    public static let maxFieldCount = 64

    /// Canonical object type name.
    public let objectType: String
    /// Canonical core type name.
    ///
    /// This remains textual at the model boundary so the standalone model
    /// package does not depend on the protocol package's core-type inventory.
    public let coreType: String
    /// Number of occupied descriptors in ``fields``.
    public let fieldCount: Int

    private let fields: InlineArray<64, ObjectFieldDescriptor>

    /// Creates an immutable schema descriptor from an inline table.
    public init(
        objectType: String,
        coreType: String,
        fieldCount: Int,
        fields: InlineArray<64, ObjectFieldDescriptor>
    ) {
        self.objectType = objectType
        self.coreType = coreType
        self.fieldCount = min(max(0, fieldCount), Self.maxFieldCount)
        self.fields = fields
    }

    /// Creates an empty schema descriptor. Useful for a manual zero-field
    /// conformance and for compile-time macro probes.
    public init(objectType: String = "", coreType: String = "", fieldCount: Int = 0) {
        self.init(
            objectType: objectType,
            coreType: coreType,
            fieldCount: fieldCount,
            fields: InlineArray(repeating: .empty)
        )
    }

    /// Returns the descriptor at `index`, or `nil` outside the occupied range.
    public subscript(index: Int) -> ObjectFieldDescriptor? {
        guard index >= 0, index < fieldCount else { return nil }
        return fields[index]
    }

    /// Returns all occupied descriptors in stable source order.
    ///
    /// The returned array is intended for host inspection and diagnostics. The
    /// runtime lookup path should use ``subscript(_:)`` to avoid a collection.
    #if !hasFeature(Embedded)
    public var fieldDescriptors: [ObjectFieldDescriptor] {
        var result: [ObjectFieldDescriptor] = []
        result.reserveCapacity(fieldCount)
        for index in 0..<fieldCount { result.append(fields[index]) }
        return result
    }
    #endif
}

/// A bounded decoder handed to a typed schema conformance.
///
/// The storage and JSON token semantics are supplied by the object-foundation
/// layer. This façade is intentionally synchronous and non-escaping so a
/// schema cannot retain borrowed wire data.
public struct ObjectFieldDecoder: ~Copyable {
    /// Creates an empty decoder for manual schema construction and tests.
    public init() {}
}

/// A bounded encoder handed to a typed schema conformance.
public struct ObjectFieldEncoder: ~Copyable {
    /// Creates an empty encoder for manual schema construction and tests.
    public init() {}
}

/// A typed schema decoding failure.
public enum ObjectDecodingError: Error, Sendable, Equatable {
    /// The schema did not contain a required field.
    case missingRequiredField(String)
    /// A field had a value of the wrong wire kind.
    case invalidField(String)
    /// The input exceeded one of the schema's static bounds.
    case capacityExceeded
}

/// A typed schema encoding failure.
public enum ObjectEncodingError: Error, Sendable, Equatable {
    /// A field could not be represented in the declared wire shape.
    case invalidField(String)
    /// The encoded object exceeded one of the schema's static bounds.
    case capacityExceeded
}

/// A portable typed object schema.
///
/// Both generated and hand-written models expose the same static descriptor.
/// Coding remains an explicit model concern; runtime storage is provided by
/// ``BoundedObject`` and the foundation object-field implementation.
public protocol ObjectSchema: Sendable {
    /// The immutable descriptor for this object type.
    static var schema: PortableObjectSchema<Self> { get }
}

/// A marker used by manual conformances to document defaulted fields.
public protocol ObjectSchemaDefaultValue {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

