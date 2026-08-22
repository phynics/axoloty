// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A typed, capacity-specialized view over a portable object schema.
///
/// The value is kept as the schema's model type. Raw envelope storage and
/// dynamic unknown fields are layered by the foundation object implementation;
/// this wrapper owns only the typed key-path surface, so typed and manual
/// schemas use exactly the same forwarding rules.
@dynamicMemberLookup
public struct BoundedObject<
    Schema: ObjectSchema,
    let unknownByteCapacity: Int,
    let unknownFieldCapacity: Int
>: Sendable where Schema: Sendable {
    private var value: Schema

    /// Creates a typed object from its model value.
    public init(_ value: consuming Schema) {
        self.value = value
    }

    /// The schema descriptor used by this object.
    public static var schema: PortableObjectSchema<Schema> { Schema.schema }

    /// The typed model value.
    public borrowing var model: Schema { value }

    /// Forwards a typed read or write to the model's ordinary writable key path.
    public subscript<Member>(dynamicMember keyPath: WritableKeyPath<Schema, Member>) -> Member {
        get { value[keyPath: keyPath] }
        set { value[keyPath: keyPath] = newValue }
    }
}

/// Host-sized typed object preset.
public typealias Object<Schema: ObjectSchema> = BoundedObject<Schema, 1024, 64>

/// ESP32-C6-sized typed object preset. The capacities are intentionally named
/// presets so evidence can revise them without changing schema source code.
public typealias StaticObject<Schema: ObjectSchema> = BoundedObject<Schema, 520, 16>

