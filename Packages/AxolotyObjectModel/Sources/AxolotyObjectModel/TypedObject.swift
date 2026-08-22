// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A typed object owning its bounded raw representation and decoded model.
@dynamicMemberLookup
public struct BoundedObject<
    Schema: ObjectSchema,
    let byteCapacity: Int,
    let fieldCapacity: Int
>: ~Copyable, Sendable where Schema: Sendable {
    private var dynamic: BoundedDynamicObject<byteCapacity, fieldCapacity>
    private var model: Schema

    /// The descriptor used for envelope validation and registry recognition.
    public static var schema: PortableObjectSchema<Schema> { Schema.schema }

    /// Creates a typed object from a complete object payload.
    public init(decoding bytes: ByteSlice) throws(ObjectError) {
        do throws(ObjectSchemaValidationError) { try Schema.schema.validate() }
        catch { throw ObjectError(.invalidSchema) }
        let dynamic = try BoundedDynamicObject<byteCapacity, fieldCapacity>(decoding: bytes)
        try validateObjectIdentity(
            decoding: bytes,
            objectType: Schema.schema.objectType,
            coreType: Schema.schema.coreType
        )
        let model: Schema
        do {
            model = try dynamic.withFields { fields in
                try fields.withDecoder { decoder in try Schema(decoding: decoder) }
            }
        } catch {
            throw ObjectError(.invalidField)
        }
        self.dynamic = dynamic
        self.model = model
    }

    /// Creates a typed object and records its schema in a caller-owned registry.
    ///
    /// The object is decoded before registration is attempted. A failed decode
    /// or failed registration therefore leaves the caller's registry unchanged.
    public init<let registryCapacity: Int>(
        decoding bytes: ByteSlice,
        using registry: inout ObjectSchemaRegistry<registryCapacity>
    ) throws(ObjectError) {
        let decoded = try Self(decoding: bytes)
        do throws(ObjectSchemaRegistryError) {
            try registry.use(Schema.self)
        } catch .capacityExceeded {
            throw ObjectError(.capacityExceeded)
        } catch {
            throw ObjectError(.invalidSchema)
        }
        self = decoded
    }

    /// Borrows the typed model without exposing raw storage.
    public var value: Schema { model }

    /// Applies a typed edit and commits raw/model state together.
    public mutating func edit(_ body: (inout Schema) throws -> Void) throws(ObjectError) {
        var nextModel = model
        do { try body(&nextModel) } catch { throw ObjectError(.invalidEditValue) }
        do {
            try dynamic.edit { editor in
                try nextModel.encodeFields(to: &editor)
            }
        } catch let error as ObjectError {
            switch error.reason {
            case .capacityExceeded, .fieldIndexOverflow: throw error
            default: throw ObjectError(.invalidEditValue, byteOffset: error.byteOffset)
            }
        } catch let error as ObjectEncodingError {
            throw error == .capacityExceeded ? ObjectError(.capacityExceeded) : ObjectError(.invalidEditValue)
        } catch { throw ObjectError(.invalidEditValue) }
        model = nextModel
    }

    /// Forwards typed reads to a writable key path. Writes must use ``edit(_:)``.
    public subscript<Member>(dynamicMember keyPath: KeyPath<Schema, Member>) -> Member {
        model[keyPath: keyPath]
    }

    /// Borrows unknown/raw fields synchronously.
    public borrowing func withFields<R>(_ body: (borrowing ObjectFields) -> R) -> R {
        dynamic.withFields(body)
    }

    /// Borrows the current envelope snapshot without creating a second mutable state.
    public borrowing func withEnvelope<let nameCapacity: Int, let externalIDCapacity: Int, R>(
        _ body: (ObjectEnvelope<nameCapacity, externalIDCapacity>) -> R
    ) throws(ObjectError) -> R {
        try dynamic.withEnvelope(body)
    }
}

/// The protocol-sized dynamic object convenience form.
///
/// The 512-byte and 24-field values are wire-authority bounds, not host or
/// embedded memory measurements. Use ``BoundedDynamicObject`` when a caller
/// has a different measured arena or descriptor capacity.
public typealias DynamicObject = BoundedDynamicObject<512, 24>

/// The protocol-sized typed object convenience form.
///
/// The 512-byte and 24-field values are wire-authority bounds, not host or
/// embedded memory measurements. Use ``BoundedObject`` for explicit capacities.
public typealias Object<Schema: ObjectSchema> = BoundedObject<Schema, 512, 24>
