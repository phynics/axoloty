// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A stable, structured failure raised while decoding or editing an object.
public struct ObjectError: Error, Sendable, Equatable {
    /// The category of the failure.
    public enum Reason: UInt8, Sendable, Equatable {
        /// The input was not one complete JSON object.
        case invalidObject
        /// A field key or value was malformed.
        case invalidField
        /// A field occurred more than once.
        case duplicateField
        /// The inline arena or descriptor table is full.
        case capacityExceeded
        /// An edit value was not valid JSON.
        case invalidEditValue
        /// An envelope member had the wrong shape or was absent.
        case invalidEnvelope
        /// The wire tokenizer's authoritative 24-field index was exceeded.
        case fieldIndexOverflow
    }

    /// The machine-readable category.
    public let reason: Reason
    /// The byte offset associated with the error, when known.
    public let byteOffset: Int

    /// Creates a structured object error.
    public init(_ reason: Reason, byteOffset: Int = 0) {
        self.reason = reason
        self.byteOffset = byteOffset
    }
}

/// A Foundation-free object identifier backed by ``UUID16``.
public struct ObjectID: Equatable, Hashable, Sendable {
    /// The underlying fixed-size identifier.
    public let uuid: UUID16

    /// Creates an object identifier from a fixed-size UUID.
    public init(uuid: UUID16) { self.uuid = uuid }

    /// Parses a hyphenated UUID borrowed from a wire buffer.
    public init?(bytes: ByteSlice) {
        guard let uuid = UUID16(parsing: bytes) else { return nil }
        self.uuid = uuid
    }
}

/// A bounded, owned object-type identifier. It never owns a ``String``.
public struct ObjectType: Equatable, Hashable, Sendable {
    private static let capacity = 128
    private var storage: InlineArray<128, UInt8>
    /// Number of meaningful UTF-8 bytes in this type identifier.
    public private(set) var length: Int

    /// Creates a type identifier from an ASCII/static UTF-8 literal.
    public init?(_ value: StaticString) {
        let count = value.utf8CodeUnitCount
        guard count <= Self.capacity else { return nil }
        storage = InlineArray(repeating: 0)
        length = count
        for index in 0..<count { storage[index] = value.utf8Start[index] }
    }

    /// Copies a borrowed UTF-8 type identifier into bounded storage.
    public init?(bytes: ByteSlice) {
        guard bytes.length <= Self.capacity else { return nil }
        storage = InlineArray(repeating: 0)
        length = bytes.length
        for index in 0..<bytes.length { storage[index] = bytes.byte(at: index)! }
    }

    /// Compares the type against a static UTF-8 literal without allocation.
    public func equals(_ value: StaticString) -> Bool {
        guard length == value.utf8CodeUnitCount else { return false }
        for index in 0..<length where storage[index] != value.utf8Start[index] { return false }
        return true
    }

    public static func == (lhs: ObjectType, rhs: ObjectType) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(length)
        for index in 0..<length { hasher.combine(storage[index]) }
    }
}

/// A bounded owned JSON-string-content byte value used for common metadata.
/// Escape sequences are retained exactly; this type does not claim Unicode decoding.
public struct BoundedEncodedText<let capacity: Int>: Equatable, Hashable, Sendable {
    private var storage: InlineArray<capacity, UInt8>
    /// Number of meaningful bytes.
    public private(set) var length: Int

    /// Copies UTF-8 bytes from a borrowed wire slice.
    public init?(bytes: ByteSlice) {
        guard bytes.length <= capacity else { return nil }
        storage = InlineArray(repeating: 0); length = bytes.length
        for index in 0..<length { storage[index] = bytes.byte(at: index)! }
    }

    /// Creates bounded text from a static UTF-8 literal.
    public init?(_ value: StaticString) {
        guard value.utf8CodeUnitCount <= capacity else { return nil }
        storage = InlineArray(repeating: 0); length = value.utf8CodeUnitCount
        for index in 0..<length { storage[index] = value.utf8Start[index] }
    }

    /// Compares the retained encoded JSON-string content with a static value.
    public borrowing func encodedEquals(_ value: StaticString) -> Bool {
        guard length == value.utf8CodeUnitCount else { return false }
        for index in 0..<length where storage[index] != value.utf8Start[index] { return false }
        return true
    }

    /// Encodes this retained string into a transactional object editor.
    public borrowing func encodeField<let editorCapacity: Int>(
        _ key: StaticString,
        to editor: inout ObjectEditor<editorCapacity>
    ) throws(ObjectError) {
        let localStorage = storage
        var failure: ObjectError?
        withUnsafeBytes(of: localStorage) { buffer in
            let bytes = ByteSlice(
                bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                length: length
            )
            do throws(ObjectError) { try editor.setEncodedString(key, value: bytes) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Writes this encoded string value synchronously without exposing its storage.
    ///
    /// The writer validates escapes and copies bytes into its caller-owned
    /// output buffer before this borrow ends.
    public borrowing func writeEncodedStringField(
        _ key: StaticString,
        to writer: inout WireWriter
    ) throws(WireEncodeError) {
        let localLength = length
        let localStorage = storage
        var failure: WireEncodeError?
        withUnsafeBytes(of: localStorage) { (buffer: UnsafeRawBufferPointer) -> Void in
            let bytes = ByteSlice(
                bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                length: localLength
            )
            do throws(WireEncodeError) { try writer.writeEncodedStringField(key, bytes) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(length)
        for index in 0..<length { hasher.combine(storage[index]) }
    }
}

/// The exact Coaty Core Profile values carried by an object envelope.
public enum ObjectCoreType: Sendable, Equatable {
    /// CoatyObject.
    case coatyObject
    /// User.
    case user
    /// Annotation.
    case annotation
    /// Task.
    case task
    /// IoSource.
    case ioSource
    /// IoActor.
    case ioActor
    /// IoNode.
    case ioNode
    /// IoContext.
    case ioContext
    /// Identity.
    case identity
    /// Log.
    case log
    /// Location.
    case location
    /// Snapshot.
    case snapshot
    /// An unknown core value with its bounded raw spelling preserved.
    case unknown(ObjectType)

    init?(bytes: ByteSlice) {
        if bytes.equals("CoatyObject") { self = .coatyObject }
        else if bytes.equals("User") { self = .user }
        else if bytes.equals("Annotation") { self = .annotation }
        else if bytes.equals("Task") { self = .task }
        else if bytes.equals("IoSource") { self = .ioSource }
        else if bytes.equals("IoActor") { self = .ioActor }
        else if bytes.equals("IoNode") { self = .ioNode }
        else if bytes.equals("IoContext") { self = .ioContext }
        else if bytes.equals("Identity") { self = .identity }
        else if bytes.equals("Log") { self = .log }
        else if bytes.equals("Location") { self = .location }
        else if bytes.equals("Snapshot") { self = .snapshot }
        else if let raw = ObjectType(bytes: bytes) { self = .unknown(raw) }
        else { return nil }
    }
}

/// Distinguishes absent, explicit null, and present JSON values.
public enum Presence<Value> {
    /// The field did not occur in the object.
    case missing
    /// The field occurred with JSON `null`.
    case null
    /// The field occurred with a non-null value.
    case value(Value)
}

extension Presence: Sendable where Value: Sendable {}
