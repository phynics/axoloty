// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Failure returned by a fixed schema registry.
public enum ObjectSchemaRegistryError: Error, Sendable, Equatable {
    /// The table has no unused slot.
    case capacityExceeded
    /// A type name was registered with a different schema descriptor.
    case conflictingSchema(String)
    /// A schema was attempted after sealing.
    case sealed
    /// The schema has no canonical object type name.
    case invalidObjectType
}

/// A fixed-inline, runtime-local schema registry.
///
/// Registration is explicit and deterministic. Re-registering the same schema
/// is idempotent; conflicting descriptors and saturation leave the registry
/// byte-for-byte unchanged. The registry is intentionally an ordinary value
/// passed by the runtime rather than a process-global class table.
private struct ObjectSchemaRegistryEntry: Sendable {
    var occupied = false
    var objectType = ""
    var coreType = ""
    var fieldCount = 0
    var fields = InlineArray<64, ObjectFieldDescriptor>(repeating: .empty)
}

public struct ObjectSchemaRegistry<let capacity: Int>: ~Copyable {
    private var entries: InlineArray<capacity, ObjectSchemaRegistryEntry>
    private var isSealed = false

    /// Creates an empty registry.
    public init() {
        entries = InlineArray(repeating: ObjectSchemaRegistryEntry())
    }

    /// Number of schemas currently registered.
    public var count: Int {
        var result = 0
        for index in 0..<capacity where entries[index].occupied { result += 1 }
        return result
    }

    /// Adds `Schema` or verifies its existing identical registration.
    ///
    /// - Parameter schema: The schema metatype to register.
    /// - Throws: ``ObjectSchemaRegistryError`` if the type is invalid,
    ///   conflicting, sealed, or the fixed table is full.
    public mutating func use<Schema: ObjectSchema>(_ schema: Schema.Type) throws(ObjectSchemaRegistryError) {
        try register(Schema.schema)
    }

    /// Registers a descriptor directly, which is useful for generated schema
    /// catalogs that do not need to instantiate a model value.
    public mutating func register<Value: Sendable>(
        _ schema: PortableObjectSchema<Value>
    ) throws(ObjectSchemaRegistryError) {
        guard !isSealed else { throw .sealed }
        guard !schema.objectType.isEmpty else { throw .invalidObjectType }

        for index in 0..<capacity where entries[index].occupied {
            guard entries[index].objectType == schema.objectType else { continue }
            guard entries[index].coreType == schema.coreType,
                  entries[index].fieldCount == schema.fieldCount else {
                throw .conflictingSchema(schema.objectType)
            }
            for fieldIndex in 0..<schema.fieldCount {
                guard let current = schema[fieldIndex],
                      entries[index].fields[fieldIndex] == current else {
                    throw .conflictingSchema(schema.objectType)
                }
            }
            return
        }

        for index in 0..<capacity where !entries[index].occupied {
            var entry = ObjectSchemaRegistryEntry(
                occupied: true,
                objectType: schema.objectType,
                coreType: schema.coreType,
                fieldCount: schema.fieldCount,
                fields: InlineArray(repeating: .empty)
            )
            for fieldIndex in 0..<schema.fieldCount {
                if let field = schema[fieldIndex] { entry.fields[fieldIndex] = field }
            }
            entries[index] = entry
            return
        }
        throw .capacityExceeded
    }

    /// Seals this registry and returns an immutable lookup view.
    public consuming func sealed() -> SealedObjectSchemaRegistry<capacity> {
        SealedObjectSchemaRegistry(entries: entries)
    }
}

/// The immutable lookup view produced by ``ObjectSchemaRegistry/sealed()``.
public struct SealedObjectSchemaRegistry<let capacity: Int>: Sendable {
    private let entries: InlineArray<capacity, ObjectSchemaRegistryEntry>

    fileprivate init(entries: InlineArray<capacity, ObjectSchemaRegistryEntry>) {
        self.entries = entries
    }

    /// Number of schemas in this sealed view.
    public var count: Int {
        var result = 0
        for index in 0..<capacity where entries[index].occupied { result += 1 }
        return result
    }

    /// Returns whether an object type was registered before sealing.
    public func contains(objectType: String) -> Bool {
        for index in 0..<capacity where entries[index].occupied && entries[index].objectType == objectType {
            return true
        }
        return false
    }
}
