// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

/// The representation negotiated for an IO endpoint.
public enum IoValueRepresentation: UInt8, Sendable, Equatable, Hashable { case json, binary }

/// A stable semantic application value type.
public struct IoValueType: Sendable, Equatable, Hashable {
    private let value: BoundedEncodedText<128>
    /// Creates a type identifier from a bounded literal.
    public init(_ literal: StaticString) throws(ProtocolError) {
        guard let value = BoundedEncodedText<128>(literal), value.length > 0 else { throw ProtocolError(.malformedPayload) }
        self.value = value
    }
    /// Copies a type identifier from bytes.
    public init(bytes: ByteSlice) throws(ProtocolError) {
        guard let value = BoundedEncodedText<128>(bytes: bytes), value.length > 0 else { throw ProtocolError(.malformedPayload) }
        self.value = value
    }
    /// Compares the identifier with a static spelling.
    public borrowing func equals(_ literal: StaticString) -> Bool { value.encodedEquals(literal) }
    /// Borrows the identifier bytes.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) -> R) -> R { value.withBytes(body) }
    /// Copies an existing bounded identifier.
    public init(copying value: borrowing BoundedEncodedText<128>) throws(ProtocolError) {
        var result: Self?
        value.withBytes { bytes in result = try? Self(bytes: bytes) }
        guard let result else { throw ProtocolError(.malformedPayload) }
        self = result
    }
    /// Encodes the identifier into an object field.
    public borrowing func encodeField<let capacity: Int>(to editor: inout ObjectFieldEncoder<capacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do throws(ObjectError) { try value.encodeField(key, to: &editor) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension IoValueType: ObjectFieldEncodable {
    public borrowing func encode<let capacity: Int>(to editor: inout ObjectFieldEncoder<capacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do throws(ObjectError) { try value.encodeField(key, to: &editor) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension IoValueType: ObjectFieldDecodable {
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var result: Self?
        guard value.withString({ bytes in result = try? Self(bytes: bytes) }), let result else { throw .invalidField }
        return result
    }
}

/// A bounded owned byte value.
public struct BoundedIoBytes<let capacity: Int>: Sendable, Equatable {
    private var storage: InlineArray<capacity, UInt8>
    /// Number of retained bytes.
    public private(set) var length: Int
    /// Creates an empty value.
    public init() { storage = InlineArray(repeating: 0); length = 0 }
    /// Copies bytes into bounded storage.
    public init(copying bytes: ByteSlice) throws(ProtocolError) {
        guard bytes.length <= capacity else { throw ProtocolError(.capacityExceeded) }
        storage = InlineArray(repeating: 0); length = bytes.length
        for index in 0..<length { storage[index] = bytes.byte(at: index)! }
    }
    /// Borrows the retained bytes.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) -> R) -> R {
        let localLength = length
        return withUnsafeBytes(of: storage) { buffer in body(ByteSlice(bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), length: localLength)) }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }
}

/// A bounded JSON payload.
public typealias BoundedJSONValue<let capacity: Int> = BoundedIoBytes<capacity>

/// Structured IO value failures.
public enum IoValueError: UInt8, Error, Sendable, Equatable { case invalidValue, capacityExceeded }

/// Common portable IO value contract.
public protocol IoValue: Sendable { static var representation: IoValueRepresentation { get } }

/// JSON IO value contract.
public protocol JSONIoValue: IoValue {
    init(ioJSON value: borrowing JSONValueView) throws(IoValueError)
    borrowing func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError)
}
/// Binary IO value contract.
public protocol BinaryIoValue: IoValue {
    init(ioBytes: borrowing ByteSlice) throws(IoValueError)
    borrowing func encodeIoBytes(into output: inout IoByteOutput) throws(IoValueError)
}
extension JSONIoValue { public static var representation: IoValueRepresentation { .json } }
extension BinaryIoValue { public static var representation: IoValueRepresentation { .binary } }

/// A fixed-capacity JSON writer.
public struct IoJSONOutput: ~Copyable, Sendable {
    private var value: BoundedJSONValue<512> = BoundedJSONValue()
    public init() {}
    /// Copies one complete JSON value.
    public mutating func writeRaw(_ bytes: ByteSlice) throws(IoValueError) {
        do throws(ProtocolError) { value = try BoundedJSONValue(copying: bytes) }
        catch { throw error.code == .capacityExceeded ? .capacityExceeded : .invalidValue }
    }
    /// Writes a static JSON literal.
    public mutating func write(_ literal: StaticString) throws(IoValueError) { try writeRaw(ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount)) }
    /// Borrows the encoded value.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) -> R) -> R { value.withBytes(body) }
    /// Finishes the output.
    public consuming func finish() -> BoundedJSONValue<512> { value }
}

/// A fixed-capacity binary writer.
public struct IoByteOutput: ~Copyable, Sendable {
    private var value: BoundedIoBytes<512> = BoundedIoBytes()
    public init() {}
    /// Copies bytes into the output.
    public mutating func write(_ bytes: ByteSlice) throws(IoValueError) {
        do throws(ProtocolError) { value = try BoundedIoBytes(copying: bytes) }
        catch { throw error.code == .capacityExceeded ? .capacityExceeded : .invalidValue }
    }
    /// Borrows the encoded value.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) -> R) -> R { value.withBytes(body) }
    /// Finishes the output.
    public consuming func finish() -> BoundedIoBytes<512> { value }
}

/// A dynamic endpoint value with a fixed registration-time representation.
public enum DynamicIoValue: Sendable, Equatable {
    case json(BoundedJSONValue<512>)
    case binary(BoundedIoBytes<512>)
    /// Returns the carried representation.
    public var representation: IoValueRepresentation { switch self { case .json: return .json; case .binary: return .binary } }
}

/// Source publication policy.
public enum IoPublicationPolicy: Sendable, Equatable { case immediate, latest(atMostEveryMS: UInt32), throttle(forMS: UInt32) }
/// Publication admission result.
public enum IoPublicationReceipt: Sendable, Equatable { case published, queuedLatest, throttled, notAssociated, rejected(ProtocolError.Code) }

/// Public association snapshot.
public struct IoAssociationState: Sendable, Equatable {
    public let generation: UInt32
    public let hasAssociations: Bool
    public let associationCount: Int
    public let recommendedUpdateRateMS: UInt32?
    public init(generation: UInt32 = 0, hasAssociations: Bool = false, associationCount: Int = 0, recommendedUpdateRateMS: UInt32? = nil) {
        self.generation = generation; self.hasAssociations = hasAssociations; self.associationCount = associationCount; self.recommendedUpdateRateMS = recommendedUpdateRateMS
    }
}

/// Copyable typed source registry key.
public struct IoSource<Value: IoValue>: Sendable, Hashable {
    public let id: ObjectID
    public init(id: ObjectID) { self.id = id }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
/// Copyable typed actor registry key.
public struct IoActor<Value: IoValue>: Sendable, Hashable {
    public let id: ObjectID
    public init(id: ObjectID) { self.id = id }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Portable source metadata; policy fields are derived by the runtime builder.
public struct IoSourceMetadata: ObjectSchema, Sendable {
    public let valueType: IoValueType
    public static let schema = ioMetadataSchema(IoSourceMetadata.self, objectType: "coaty.IoSource", coreType: .ioSource)
    public init(valueType: IoValueType) { self.valueType = valueType }
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) { self.valueType = try fields.decode("valueType", as: IoValueType.self) }
    public borrowing func encodeFields<let capacity: Int>(to encoder: inout ObjectFieldEncoder<capacity>) throws(ObjectEncodingError) { try encoder.encode(valueType, forKey: "valueType") }
}
/// Portable actor metadata; policy fields are derived by the runtime builder.
public struct IoActorMetadata: ObjectSchema, Sendable {
    public let valueType: IoValueType
    public static let schema = ioMetadataSchema(IoActorMetadata.self, objectType: "coaty.IoActor", coreType: .ioActor)
    public init(valueType: IoValueType) { self.valueType = valueType }
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) { self.valueType = try fields.decode("valueType", as: IoValueType.self) }
    public borrowing func encodeFields<let capacity: Int>(to encoder: inout ObjectFieldEncoder<capacity>) throws(ObjectEncodingError) { try encoder.encode(valueType, forKey: "valueType") }
}

private func ioMetadataSchema<Value: Sendable>(_ type: Value.Type, objectType: StaticString, coreType: ObjectCoreType) -> PortableObjectSchema<Value> {
    var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    fields[0] = ObjectFieldDescriptor(key: ObjectFieldKey("valueType")!, index: 0, flags: .required)
    return PortableObjectSchema(objectType: ObjectType(objectType)!, coreType: coreType, fieldCount: 1, fields: fields)
}
/// Portable IO context metadata.
public struct IoContext: ObjectSchema, Sendable {
    public static let schema = PortableObjectSchema<IoContext>(objectType: ObjectType("coaty.IoContext")!, coreType: .ioContext, fieldCount: 0, fields: InlineArray<24, ObjectFieldDescriptor>(repeating: .empty))
    public init() {}
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    public borrowing func encodeFields<let capacity: Int>(to encoder: inout ObjectFieldEncoder<capacity>) throws(ObjectEncodingError) {}
}
