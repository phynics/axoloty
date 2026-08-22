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
    public init(rawValue: UInt8) { self.rawValue = rawValue }
}

/// A bounded wire key stored separately from the larger object-type vocabulary.
public struct ObjectFieldKey: Sendable, Equatable {
    private let literal: StaticString
    /// Number of meaningful UTF-8 bytes.
    public let length: Int

    /// Creates a key from a static UTF-8 literal.
    public init?(_ value: StaticString) {
        guard value.utf8CodeUnitCount <= WireBufferConfig.maxTopicLength else { return nil }
        literal = value
        length = value.utf8CodeUnitCount
    }

    /// Compares the key against a static UTF-8 literal.
    public borrowing func equals(_ value: StaticString) -> Bool {
        guard length == value.utf8CodeUnitCount else { return false }
        for index in 0..<length where literal.utf8Start[index] != value.utf8Start[index] { return false }
        return true
    }

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
    public init(key: ObjectFieldKey, index: UInt8, flags: ObjectFieldFlags) {
        self.key = key
        self.index = index
        self.flags = flags
    }
}

/// An immutable fixed-inline schema descriptor shared by manual and macro forms.
public struct PortableObjectSchema<Value: Sendable>: Sendable {
    /// Maximum fields supported by the authoritative wire index.
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
    public init(
        objectType: ObjectType,
        coreType: ObjectCoreType,
        fieldCount: UInt8,
        fields: InlineArray<24, ObjectFieldDescriptor>
    ) {
        self.objectType = objectType
        self.coreType = coreType
        self.fieldCount = min(fieldCount, UInt8(Self.maxFieldCount))
        self.fields = fields
    }
}

/// A typed value that can be decoded from one borrowed JSON value.
public protocol ObjectFieldDecodable: Sendable {
    static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self
}

/// A typed value that can be encoded into a transactional object editor.
public protocol ObjectFieldEncodable: Sendable {
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

    /// Decodes one required field.
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

    /// Decodes a field while preserving missing, null, and value states.
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
    init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError)
    /// Encodes typed fields into a capacity-specialized transactional editor.
    borrowing func encodeFields<let editorCapacity: Int>(
        to encoder: inout ObjectFieldEncoder<editorCapacity>
    ) throws(ObjectEncodingError)
}

/// The fixed inline editor used by typed schema encoders.
public typealias ObjectFieldEncoder<let editorCapacity: Int> = ObjectEditor<editorCapacity>

extension ObjectEditor {
    /// Encodes one bounded primitive or application-defined field value.
    public mutating func encode<T: ObjectFieldEncodable>(
        _ value: T,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        do { try value.encode(to: &self, forKey: key) }
        catch { throw error }
    }
}

extension Optional: ObjectFieldEncodable where Wrapped: ObjectFieldEncodable {
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

extension Presence: ObjectFieldEncodable where Value: ObjectFieldEncodable {
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
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Int {
        var number: Int64?
        guard value.withNumber({ number = $0.intValue }) else { throw .invalidField }
        guard let number, number >= Int64(Int.min), number <= Int64(Int.max) else { throw .invalidField }
        return Int(number)
    }

    public func encode<let editorCapacity: Int>(to editor: inout ObjectFieldEncoder<editorCapacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do { try editor.setInteger(self, forKey: key) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension Bool: ObjectFieldDecodable, ObjectFieldEncodable {
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Bool {
        switch value.kind { case .trueValue: return true; case .falseValue: return false; default: throw .invalidField }
    }

    public func encode<let editorCapacity: Int>(to editor: inout ObjectFieldEncoder<editorCapacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do { try editor.setBoolean(self, forKey: key) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension BoundedEncodedText: ObjectFieldDecodable, ObjectFieldEncodable {
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var decoded: Self?
        _ = value.withString { bytes in decoded = Self(bytes: bytes) }
        guard let decoded else { throw .invalidField }
        return decoded
    }

    public borrowing func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        do throws(ObjectError) { try encodeField(key, to: &editor) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension ObjectID: ObjectFieldDecodable, ObjectFieldEncodable {
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var decoded: Self?
        _ = value.withString { bytes in decoded = Self(bytes: bytes) }
        guard let decoded else { throw .invalidField }
        return decoded
    }

    public func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        do { try editor.setUUID(key, value: uuid) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}
