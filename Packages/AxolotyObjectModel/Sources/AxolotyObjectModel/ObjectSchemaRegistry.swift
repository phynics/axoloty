// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Failure returned by a fixed schema registry.
public enum ObjectSchemaRegistryError: Error, Sendable, Equatable {
    /// The fixed registry has no free slot.
    case capacityExceeded
    /// The object type already has a different schema descriptor.
    case conflictingSchema
    /// The schema has no valid object type.
    case invalidObjectType
    /// The fixed descriptor table violates the portable schema contract.
    case invalidSchema
}

/// A type-erased, recognition-only schema descriptor.
public struct ObjectSchemaDescriptor: Sendable {
    /// Registered object type.
    public let objectType: ObjectType
    /// Registered core family.
    public let coreType: ObjectCoreType
    /// Number of occupied field descriptors.
    public let fieldCount: UInt8
    /// Fixed descriptors used to compare an idempotent registration.
    public let fields: InlineArray<24, ObjectFieldDescriptor>
}

@usableFromInline
struct ObjectSchemaRegistryEntry: Sendable {
    var occupied = false
    var objectType: ObjectType?
    var coreType: ObjectCoreType = .coatyObject
    var fieldCount: UInt8 = 0
    var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
}

/// A fixed-inline, runtime-local schema recognition registry.
public struct ObjectSchemaRegistry<let capacity: Int>: ~Copyable {
    private var entries: InlineArray<capacity, ObjectSchemaRegistryEntry>

    /// Creates an empty local registry.
    public init() { entries = InlineArray(repeating: ObjectSchemaRegistryEntry()) }

    /// Registers a schema or verifies its identical prior registration.
    public mutating func use<Schema: ObjectSchema>(_ schema: Schema.Type) throws(ObjectSchemaRegistryError) {
        try register(Schema.schema)
    }

    /// Registers a fixed descriptor without requiring a model instance.
    public mutating func register<Value: Sendable>(
        _ descriptor: PortableObjectSchema<Value>
    ) throws(ObjectSchemaRegistryError) {
        do throws(ObjectSchemaValidationError) { try descriptor.validate() }
        catch .invalidObjectType { throw .invalidObjectType }
        catch { throw .invalidSchema }
        for index in 0..<capacity where entries[index].occupied {
            guard entries[index].objectType == descriptor.objectType else { continue }
            guard entries[index].coreType == descriptor.coreType,
                  entries[index].fieldCount == descriptor.fieldCount,
                  fieldsMatch(entries[index].fields, descriptor.fields, count: descriptor.fieldCount) else {
                throw .conflictingSchema
            }
            return
        }
        for index in 0..<capacity where !entries[index].occupied {
            entries[index] = ObjectSchemaRegistryEntry(
                occupied: true,
                objectType: descriptor.objectType,
                coreType: descriptor.coreType,
                fieldCount: descriptor.fieldCount,
                fields: descriptor.fields
            )
            return
        }
        throw .capacityExceeded
    }

    /// Consumes this mutable registry into an immutable recognition view.
    public consuming func sealed() -> SealedObjectSchemaRegistry<capacity> {
        SealedObjectSchemaRegistry(entries: entries)
    }

    private func fieldsMatch(
        _ lhs: InlineArray<24, ObjectFieldDescriptor>,
        _ rhs: InlineArray<24, ObjectFieldDescriptor>,
        count: UInt8
    ) -> Bool {
        for index in 0..<Int(count) where lhs[index] != rhs[index] { return false }
        return true
    }
}

/// The immutable view of a sealed schema registry.
public struct SealedObjectSchemaRegistry<let capacity: Int>: Sendable {
    private let entries: InlineArray<capacity, ObjectSchemaRegistryEntry>

    fileprivate init(entries: InlineArray<capacity, ObjectSchemaRegistryEntry>) { self.entries = entries }

    /// Returns whether an object type was registered.
    public func contains(_ objectType: ObjectType) -> Bool {
        for index in 0..<capacity where entries[index].occupied && entries[index].objectType == objectType { return true }
        return false
    }

    /// Number of schemas in this sealed registry.
    public var count: Int {
        var result = 0
        for index in 0..<capacity where entries[index].occupied { result += 1 }
        return result
    }

    /// Returns the fixed recognition descriptor for a registered type.
    public func descriptor(for objectType: ObjectType) -> ObjectSchemaDescriptor? {
        for index in 0..<capacity where entries[index].occupied && entries[index].objectType == objectType {
            let entry = entries[index]
            return ObjectSchemaDescriptor(
                objectType: entry.objectType!, coreType: entry.coreType,
                fieldCount: entry.fieldCount, fields: entry.fields
            )
        }
        return nil
    }
}
