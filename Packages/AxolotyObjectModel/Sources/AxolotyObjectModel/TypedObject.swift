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
        let dynamic = try BoundedDynamicObject<byteCapacity, fieldCapacity>(decoding: bytes)
        // These explicit preset bounds keep envelope decoding from inheriting
        // an arbitrary default; callers can use `withEnvelope` for other bounds.
        let envelope = try dynamic.withEncodedBytes { encoded in
            try ObjectEnvelope<64, 128>(decoding: encoded)
        }
        guard envelope.objectType == Schema.schema.objectType,
              envelope.coreType == Schema.schema.coreType else { throw ObjectError(.invalidEnvelope) }
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

/// The measured host/embedded payload preset: one wire payload and its 24-key index.
public typealias Object<Schema: ObjectSchema> = BoundedObject<Schema, 512, 24>

/// The fixed-inline preset used when a schema does not need a larger arena.
public typealias StaticObject<Schema: ObjectSchema> = BoundedObject<Schema, 512, 24>
