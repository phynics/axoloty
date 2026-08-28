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

    /// Creates a typed object from an envelope and its typed field model.
    ///
    /// The schema, envelope, fields, and final wire representation are
    /// validated before this value is initialized. A capacity or encoding
    /// failure therefore cannot leave a partially initialized object.
    ///
    /// - Parameters:
    ///   - envelope: The common object identity and lifecycle fields.
    ///   - fields: The typed schema value to encode and retain.
    /// - Throws: ``ObjectError`` when the schema, envelope identity, field
    ///   values, or bounded storage are invalid.
    public init<let nameCapacity: Int, let externalIDCapacity: Int>(
        envelope: ObjectEnvelope<nameCapacity, externalIDCapacity>,
        fields: consuming Schema
    ) throws(ObjectError) {
        do throws(ObjectSchemaValidationError) { try Schema.schema.validate() }
        catch { throw ObjectError(.invalidSchema) }
        guard envelope.objectType == Schema.schema.objectType,
              envelope.coreType == Schema.schema.coreType else {
            throw ObjectError(.invalidEnvelope)
        }
        guard byteCapacity >= 2 else { throw ObjectError(.capacityExceeded) }

        var editor = ObjectEditor<byteCapacity>(empty: ())
        do throws(ObjectError) {
            try envelope.encode(to: &editor)
        } catch {
            throw error
        }
        do throws(ObjectEncodingError) {
            try fields.encodeFields(to: &editor)
        } catch {
            throw error == .capacityExceeded
                ? ObjectError(.capacityExceeded)
                : ObjectError(.invalidField)
        }

        let dynamic = try BoundedDynamicObject<byteCapacity, fieldCapacity>(committing: &editor)
        let model: Schema
        do throws(ObjectDecodingError) { model = try dynamic.decode(Schema.self) }
        catch { throw ObjectError(.invalidField) }
        self.dynamic = dynamic
        self.model = model
    }

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
        do throws(ObjectDecodingError) { model = try dynamic.decode(Schema.self) }
        catch { throw ObjectError(.invalidField) }
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
            try dynamic.editEncodedFields(nextModel)
        } catch {
            throw error
        }
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

    /// Borrows the canonical encoded object bytes for the duration of `body`.
    ///
    /// - Parameter body: A synchronous operation receiving the borrowed bytes.
    /// - Returns: The value returned by `body`.
    /// - Throws: Any error thrown by `body`.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try dynamic.withEncodedBytes(body)
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
/// The 2,048-byte and 24-field values are wire-authority bounds, not host or
/// embedded memory measurements. Use ``BoundedDynamicObject`` when a caller
/// has a different measured arena or descriptor capacity.
public typealias DynamicObject = BoundedDynamicObject<2048, 24>

/// The protocol-sized typed object convenience form.
///
/// The 2,048-byte and 24-field values are wire-authority bounds, not host or
/// embedded memory measurements. Use ``BoundedObject`` for explicit capacities.
public typealias Object<Schema: ObjectSchema> = BoundedObject<Schema, 2048, 24>
