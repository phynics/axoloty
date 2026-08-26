// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// Errors raised while decoding a typed schema.
public enum ObjectDecodingError: Error, Sendable, Equatable {
    /// A required field was absent.
    case missingRequiredField
    /// A field had an incompatible JSON kind or value.
    case invalidField
    /// A bounded field or object limit was exceeded.
    case capacityExceeded
}

/// Errors raised while encoding a typed schema.
public enum ObjectEncodingError: Error, Sendable, Equatable {
    /// A field could not be represented by the bounded wire codec.
    case invalidField
    /// A bounded field or object limit was exceeded.
    case capacityExceeded
}

/// A manually-authored schema descriptor failed fixed wire validation.
public enum ObjectSchemaValidationError: Error, Sendable, Equatable {
    /// The schema has no object type identifier.
    case invalidObjectType
    /// The descriptor count exceeds the authoritative wire index.
    case invalidFieldCount
    /// A field key is reserved for the common object envelope.
    case reservedFieldKey
    /// Two fields use the same wire key.
    case duplicateFieldKey
    /// Two fields use the same descriptor index.
    case duplicateFieldIndex
    /// A descriptor index lies outside the occupied field range.
    case invalidFieldIndex
    /// A descriptor has an unsupported flag combination.
    case invalidFlags
    /// A descriptor after `fieldCount` is not the empty sentinel.
    case nonEmptyTrailingField
}

/// A field's wire presence policy.
public struct ObjectFieldFlags: OptionSet, Sendable, Equatable {
    /// A field must be present on decode.
    public static let required = Self(rawValue: 1 << 0)
    /// A field may be omitted and maps to an optional value.
    public static let optional = Self(rawValue: 1 << 1)
    /// A field has a generated/manual default when omitted.
    public static let defaulted = Self(rawValue: 1 << 2)
    /// A field preserves missing/null/value distinction.
    public static let presence = Self(rawValue: 1 << 3)

    /// The compact flag representation.
    public let rawValue: UInt8

    /// Creates a flag set from its bounded raw bits.
    ///
    /// - Parameter rawValue: The bits describing the field policy.
    public init(rawValue: UInt8) { self.rawValue = rawValue }
}

/// A bounded wire key stored separately from the larger object-type vocabulary.
public struct ObjectFieldKey: Sendable, Equatable {
    private let literal: StaticString
    /// Number of meaningful UTF-8 bytes.
    ///
    /// - Returns: The encoded byte count of this key.
    public var length: Int { literal.utf8CodeUnitCount }

    /// Creates a key from a static UTF-8 literal.
    ///
    /// - Parameter value: The literal to retain.
    /// - Returns: A key, or `nil` when the literal exceeds the wire bound.
    public init?(_ value: StaticString) {
        guard value.utf8CodeUnitCount <= WireBufferConfig.maxTopicLength else { return nil }
        literal = value
    }

    /// Compares the key against a static UTF-8 literal.
    ///
    /// - Parameter value: The static key to compare.
    /// - Returns: `true` when the encoded bytes match exactly.
    public borrowing func equals(_ value: StaticString) -> Bool {
        guard length == value.utf8CodeUnitCount else { return false }
        for index in 0..<length where literal.utf8Start[index] != value.utf8Start[index] { return false }
        return true
    }

    /// Compares decoded JSON-key semantics, including escaped equivalents.
    ///
    /// - Parameter value: The static key to compare after JSON unescaping.
    /// - Returns: `true` when the decoded key semantics match.
    public borrowing func semanticEquals(_ value: StaticString) -> Bool {
        ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount).semanticEquals(value)
    }

    /// Compares two keys using decoded JSON-key semantics.
    ///
    /// - Parameter other: The key to compare after JSON unescaping.
    /// - Returns: `true` when the decoded key semantics match.
    public borrowing func semanticEquals(_ other: ObjectFieldKey) -> Bool {
        ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount).semanticEquals(
            ByteSlice(bytes: other.literal.utf8Start, length: other.literal.utf8CodeUnitCount)
        )
    }

    /// Compares two keys by their retained encoded UTF-8 bytes.
    ///
    /// - Parameters:
    ///   - lhs: The first key.
    ///   - rhs: The second key.
    /// - Returns: `true` when both keys have identical encoded bytes.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.literal.utf8Start[index] != rhs.literal.utf8Start[index] { return false }
        return true
    }
}

/// A fixed descriptor for one typed schema field.
public struct ObjectFieldDescriptor: Sendable, Equatable {
    /// An unused fixed-table entry.
    public static let empty = ObjectFieldDescriptor(key: ObjectFieldKey("")!, index: 0, flags: [])
    /// The field's bounded wire key.
    public let key: ObjectFieldKey
    /// Stable source-order field index.
    public let index: UInt8
    /// Presence/default policy.
    public let flags: ObjectFieldFlags

    /// Creates a field descriptor.
    ///
    /// - Parameters:
    ///   - key: The bounded wire key.
    ///   - index: The stable descriptor index.
    ///   - flags: The field's presence and default policy.
    public init(key: ObjectFieldKey, index: UInt8, flags: ObjectFieldFlags) {
        self.key = key
        self.index = index
        self.flags = flags
    }
}

/// An immutable fixed-inline schema descriptor shared by manual and macro forms.
public struct PortableObjectSchema<Value: Sendable>: Sendable {
    /// Maximum fields supported by the authoritative wire index.
    ///
    /// - Returns: The fixed field-count limit.
    public static var maxFieldCount: Int { WireBufferConfig.maxIndexedFields }
    /// Object type carried by this schema.
    public let objectType: ObjectType
    /// Core type carried by this schema.
    public let coreType: ObjectCoreType
    /// Number of occupied descriptors.
    public let fieldCount: UInt8
    /// Fixed descriptor table. Entries after `fieldCount` are empty.
    public let fields: InlineArray<24, ObjectFieldDescriptor>

    /// Creates a schema from its fixed descriptor table.
    ///
    /// - Parameters:
    ///   - objectType: The bounded object type identifier.
    ///   - coreType: The Coaty core family.
    ///   - fieldCount: The number of occupied descriptors.
    ///   - fields: The fixed descriptor table.
    public init(
        objectType: ObjectType,
        coreType: ObjectCoreType,
        fieldCount: UInt8,
        fields: InlineArray<24, ObjectFieldDescriptor>
    ) {
        self.objectType = objectType
        self.coreType = coreType
        self.fieldCount = fieldCount
        self.fields = fields
    }

    /// Validates the fixed descriptor invariants shared by manual and macro schemas.
    ///
    /// - Throws: ``ObjectSchemaValidationError`` when the descriptor count,
    ///   keys, indices, flags, or trailing entries violate the schema contract.
    public func validate() throws(ObjectSchemaValidationError) {
        guard objectType.length > 0 else { throw .invalidObjectType }
        guard fieldCount <= UInt8(Self.maxFieldCount) else { throw .invalidFieldCount }
        var index = 0
        while index < Int(fieldCount) {
            let field = fields[index]
            guard field.key.length > 0 else { throw .invalidFieldCount }
            guard !isReservedObjectFieldKey(field.key) else { throw .reservedFieldKey }
            guard field.index < fieldCount else { throw .invalidFieldIndex }
            let required = field.flags.contains(.required)
            let optional = field.flags.contains(.optional)
            let defaulted = field.flags.contains(.defaulted)
            let presence = field.flags.contains(.presence)
            guard required != optional,
                  field.flags.rawValue & 0xF0 == 0,
                  (!defaulted || (required && !presence)),
                  (!presence || (required && !defaulted)) else { throw .invalidFlags }
            var prior = 0
            while prior < index {
                if fields[prior].key.semanticEquals(field.key) { throw .duplicateFieldKey }
                if fields[prior].index == field.index { throw .duplicateFieldIndex }
                prior += 1
            }
            index += 1
        }
        index = Int(fieldCount)
        while index < Self.maxFieldCount {
            guard fields[index] == .empty else { throw .nonEmptyTrailingField }
            index += 1
        }
    }
}

@usableFromInline
func isReservedObjectFieldKey(_ key: ObjectFieldKey) -> Bool {
    key.semanticEquals("objectId") || key.semanticEquals("objectType") || key.semanticEquals("name") ||
        key.semanticEquals("coreType") || key.semanticEquals("externalId") || key.semanticEquals("parentObjectId") ||
        key.semanticEquals("locationId") || key.semanticEquals("isDeactivated")
}

/// A typed value that can be decoded from one borrowed JSON value.
public protocol ObjectFieldDecodable: Sendable {
    /// Decodes one borrowed JSON value into the conforming type.
    ///
    /// - Parameter value: The value to decode. The borrow is valid only for
    ///   the duration of this call.
    /// - Returns: The decoded value.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value cannot
    ///   be represented by the conforming type.
    static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self
}

/// A typed value that can be encoded into a transactional object editor.
public protocol ObjectFieldEncodable: Sendable {
    /// Encodes the value into a caller-owned transactional editor.
    ///
    /// - Parameters:
    ///   - editor: The editor receiving the encoded field.
    ///   - key: The bounded wire key for the field.
    /// - Throws: ``ObjectEncodingError/invalidField`` when the value cannot
    ///   be represented, or ``ObjectEncodingError/capacityExceeded`` when
    ///   the editor has no room.
    func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError)
}

/// A bounded decoder over one synchronous object-field borrow.
public struct ObjectFieldDecoder: ~Copyable {
    private let bytes: UnsafeRawPointer
    private let length: Int

    @usableFromInline
    init(bytes: UnsafeRawPointer, length: Int) {
        self.bytes = bytes
        self.length = length
    }

    /// Borrows the complete encoded field object for the duration of `body`.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try body(ByteSlice(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length))
    }

    /// Decodes one required field.
    ///
    /// - Parameters:
    ///   - key: The bounded wire key to find.
    ///   - type: The expected decoded value type.
    /// - Returns: The decoded field value.
    /// - Throws: ``ObjectDecodingError/missingRequiredField`` when the key is
    ///   absent, or ``ObjectDecodingError/invalidField`` when the input or
    ///   value has an invalid shape.
    public borrowing func decode<T: ObjectFieldDecodable>(
        _ key: StaticString,
        as type: T.Type
    ) throws(ObjectDecodingError) -> T {
        let reader = WireReader(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length)
        do throws(WireDecodeError) { try reader.validate() }
        catch { throw .invalidField }
        guard let raw = reader.readField(key) else { throw .missingRequiredField }
        let value = JSONValueView(raw: raw)
        do { return try T.decode(from: value) }
        catch { throw .invalidField }
    }

    /// Decodes an optional field, preserving omission and JSON null as `nil`.
    ///
    /// - Parameters:
    ///   - key: The bounded wire key to find.
    ///   - type: The expected decoded value type.
    /// - Returns: The decoded value, or `nil` for omission or JSON `null`.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the input or value
    ///   has an invalid shape.
    public borrowing func decodeIfPresent<T: ObjectFieldDecodable>(
        _ key: StaticString,
        as type: T.Type
    ) throws(ObjectDecodingError) -> T? {
        let reader = WireReader(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length)
        do throws(WireDecodeError) { try reader.validate() }
        catch { throw .invalidField }
        guard let raw = reader.readField(key) else { return nil }
        let value = JSONValueView(raw: raw)
        guard !value.isNull else { return nil }
        do { return try T.decode(from: value) }
        catch { throw .invalidField }
    }

    /// Decodes a field with a default used only when the key is absent.
    /// Explicit JSON `null` remains an invalid value for the bounded type.
    ///
    /// - Parameters:
    ///   - key: The bounded wire key to find.
    ///   - type: The expected decoded value type.
    ///   - defaultValue: The value to use when the key is absent.
    /// - Returns: The decoded field value or `defaultValue` when omitted.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the input, null,
    ///   or value has an invalid shape.
    public borrowing func decodeWithDefault<T: ObjectFieldDecodable>(
        _ key: StaticString,
        as type: T.Type,
        default defaultValue: T
    ) throws(ObjectDecodingError) -> T {
        let reader = WireReader(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length)
        do throws(WireDecodeError) { try reader.validate() }
        catch { throw .invalidField }
        guard let raw = reader.readField(key) else { return defaultValue }
        let value = JSONValueView(raw: raw)
        guard !value.isNull else { throw .invalidField }
        do { return try T.decode(from: value) }
        catch { throw .invalidField }
    }

    /// Decodes a field while preserving missing, null, and value states.
    ///
    /// - Parameters:
    ///   - key: The bounded wire key to find.
    ///   - type: The expected decoded value type.
    /// - Returns: The field's ``Presence`` state.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the input or value
    ///   has an invalid shape.
    public borrowing func presence<T: ObjectFieldDecodable>(
        _ key: StaticString,
        as type: T.Type
    ) throws(ObjectDecodingError) -> Presence<T> {
        let reader = WireReader(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length)
        do throws(WireDecodeError) { try reader.validate() }
        catch { throw .invalidField }
        guard let raw = reader.readField(key) else { return .missing }
        let value = JSONValueView(raw: raw)
        if value.isNull { return .null }
        do { return .value(try T.decode(from: value)) }
        catch { throw .invalidField }
    }
}

/// The schema contract implemented by manual and generated models.
public protocol ObjectSchema: Sendable {
    /// Immutable schema metadata.
    static var schema: PortableObjectSchema<Self> { get }
    /// Decodes typed fields from a borrowed object view.
    ///
    /// - Parameter fields: The synchronous decoder for the object's fields.
    /// - Throws: ``ObjectDecodingError`` when a required field is absent or a
    ///   field value has an invalid shape.
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError)
    /// Encodes typed fields into a capacity-specialized transactional editor.
    ///
    /// - Parameter encoder: The transactional editor receiving typed fields.
    /// - Throws: ``ObjectEncodingError`` when a field is invalid or capacity
    ///   is exhausted.
    borrowing func encodeFields<let editorCapacity: Int>(
        to encoder: inout ObjectFieldEncoder<editorCapacity>
    ) throws(ObjectEncodingError)
}

/// The fixed inline editor used by typed schema encoders.
public typealias ObjectFieldEncoder<let editorCapacity: Int> = ObjectEditor<editorCapacity>

extension ObjectEditor {
    /// Encodes one bounded primitive or application-defined field value.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - key: The bounded wire key for the value.
    /// - Throws: ``ObjectEncodingError`` when encoding fails.
    public mutating func encode<T: ObjectFieldEncodable>(
        _ value: T,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        do { try value.encode(to: &self, forKey: key) }
        catch { throw error }
    }

    /// Encodes a field, omitting it when it equals its canonical default.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - defaultValue: The canonical value to omit.
    ///   - key: The bounded wire key for the value.
    /// - Throws: ``ObjectEncodingError`` when removal or encoding fails.
    public mutating func encodeDefault<T: ObjectFieldEncodable & Equatable>(
        _ value: T,
        default defaultValue: T,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        if value == defaultValue {
            do { try remove(key) }
            catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
        } else {
            try encode(value, forKey: key)
        }
    }
}

extension Optional: ObjectFieldEncodable where Wrapped: ObjectFieldEncodable {
    /// Encodes a present optional value or removes its field when absent.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the field.
    ///   - key: The bounded wire key for the field.
    /// - Throws: ``ObjectEncodingError`` when removal or encoding fails.
    public func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        switch self {
        case .some(let value): try value.encode(to: &editor, forKey: key)
        case .none:
            do { try editor.remove(key) }
            catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
        }
    }
}

extension OwnedJSONValue: ObjectFieldDecodable {
    /// Copies one complete JSON value into the bounded owned representation.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var decoded: Self?
        value.withRaw { raw in decoded = try? Self(copying: raw) }
        guard let decoded else { throw .invalidField }
        return decoded
    }
}

extension OwnedJSONValue: ObjectFieldEncodable {
    /// Encodes the retained JSON value without stringifying or changing its
    /// original number lexeme.
    public borrowing func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        var failure: ObjectError?
        withEncodedBytes { raw in
            do throws(ObjectError) { try editor.setRaw(key, value: raw) }
            catch { failure = error }
        }
        if let failure {
            throw failure.reason == .capacityExceeded ? .capacityExceeded : .invalidField
        }
    }
}

extension Presence: ObjectFieldEncodable where Value: ObjectFieldEncodable {
    /// Encodes the missing, null, or value state without collapsing it.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the field.
    ///   - key: The bounded wire key for the field.
    /// - Throws: ``ObjectEncodingError`` when removal or encoding fails.
    public func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        switch self {
        case .missing:
            do { try editor.remove(key) }
            catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
        case .null:
            do { try editor.setNull(key) }
            catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
        case .value(let value): try value.encode(to: &editor, forKey: key)
        }
    }
}

extension Int: ObjectFieldDecodable, ObjectFieldEncodable {
    /// Decodes a JSON integer that fits the platform `Int` range.
    ///
    /// - Parameter value: The borrowed JSON value.
    /// - Returns: The decoded integer.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value is not a
    ///   representable integer.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Int {
        var number: Int64?
        guard value.withNumber({ number = $0.intValue }) else { throw .invalidField }
        guard let number, number >= Int64(Int.min), number <= Int64(Int.max) else { throw .invalidField }
        return Int(number)
    }

    /// Encodes the integer as a JSON number.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the number.
    ///   - key: The bounded wire key for the number.
    /// - Throws: ``ObjectEncodingError`` when the editor rejects the value.
    public func encode<let editorCapacity: Int>(to editor: inout ObjectFieldEncoder<editorCapacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do { try editor.setInteger(self, forKey: key) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension UInt64: ObjectFieldDecodable, ObjectFieldEncodable {
    /// Decodes a JSON integer that fits the full unsigned 64-bit range.
    ///
    /// - Parameter value: The borrowed JSON value.
    /// - Returns: The decoded unsigned integer.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value is not a
    ///   representable unsigned integer.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> UInt64 {
        var number: UInt64?
        guard value.withNumber({ number = $0.uintValue }), let number else { throw .invalidField }
        return number
    }

    /// Encodes the unsigned integer as a JSON number.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the number.
    ///   - key: The bounded wire key for the number.
    /// - Throws: ``ObjectEncodingError`` when the editor rejects the value.
    public func encode<let editorCapacity: Int>(to editor: inout ObjectFieldEncoder<editorCapacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do { try editor.setUnsignedInteger(self, forKey: key) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension Double: ObjectFieldDecodable {
    /// Decodes a finite JSON number as a `Double`.
    ///
    /// - Parameter value: The borrowed JSON value.
    /// - Returns: The decoded finite number.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value is not a
    ///   finite JSON number.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Double {
        var number: Double?
        guard value.withNumber({ number = $0.doubleValue }), let number, number.isFinite else { throw .invalidField }
        return number
    }

}

extension Bool: ObjectFieldDecodable, ObjectFieldEncodable {
    /// Decodes a JSON boolean.
    ///
    /// - Parameter value: The borrowed JSON value.
    /// - Returns: The decoded Boolean.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value is not a
    ///   JSON boolean.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Bool {
        switch value.kind { case .trueValue: return true; case .falseValue: return false; default: throw .invalidField }
    }

    /// Encodes the Boolean as a JSON literal.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the Boolean.
    ///   - key: The bounded wire key for the Boolean.
    /// - Throws: ``ObjectEncodingError`` when the editor rejects the value.
    public func encode<let editorCapacity: Int>(to editor: inout ObjectFieldEncoder<editorCapacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do { try editor.setBoolean(self, forKey: key) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension BoundedEncodedText: ObjectFieldDecodable, ObjectFieldEncodable {
    /// Decodes a bounded encoded JSON string.
    ///
    /// - Parameter value: The borrowed JSON value.
    /// - Returns: The bounded string value.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value is not a
    ///   string or exceeds the capacity.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var decoded: Self?
        _ = value.withString { bytes in decoded = Self(bytes: bytes) }
        guard let decoded else { throw .invalidField }
        return decoded
    }

    /// Encodes the retained string into the transactional editor.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the string.
    ///   - key: The bounded wire key for the string.
    /// - Throws: ``ObjectEncodingError`` when the string is invalid or the
    ///   editor has insufficient capacity.
    public borrowing func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        do throws(ObjectError) { try encodeField(key, to: &editor) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension ObjectID: ObjectFieldDecodable, ObjectFieldEncodable {
    /// Decodes a UUID string into an object identifier.
    ///
    /// - Parameter value: The borrowed JSON value.
    /// - Returns: The decoded object identifier.
    /// - Throws: ``ObjectDecodingError/invalidField`` when the value is not a
    ///   valid UUID string.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var decoded: Self?
        _ = value.withString { bytes in decoded = Self(bytes: bytes) }
        guard let decoded else { throw .invalidField }
        return decoded
    }

    /// Encodes the UUID as a JSON string.
    ///
    /// - Parameters:
    ///   - editor: The transactional editor receiving the identifier.
    ///   - key: The bounded wire key for the identifier.
    /// - Throws: ``ObjectEncodingError`` when the editor rejects the value.
    public func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        do { try editor.setUUID(key, value: uuid) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}
