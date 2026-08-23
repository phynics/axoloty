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
        /// The associated typed schema descriptor is invalid.
        case invalidSchema
        /// The wire tokenizer's authoritative 24-field index was exceeded.
        case fieldIndexOverflow
        /// A predicate program was malformed.
        case invalidPredicate
        /// A predicate path was malformed.
        case invalidPredicatePath
        /// A predicate operator or operand was malformed.
        case invalidPredicateExpression
    }

    /// The machine-readable category.
    public let reason: Reason
    /// The byte offset associated with the error, when known.
    public let byteOffset: Int

    /// Creates a structured object error.
    ///
    /// - Parameters:
    ///   - reason: The machine-readable failure category.
    ///   - byteOffset: The associated input offset, or `0` when unknown.
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
    ///
    /// - Parameter uuid: The fixed-size UUID backing the identifier.
    public init(uuid: UUID16) { self.uuid = uuid }

    /// Parses a hyphenated UUID borrowed from a wire buffer.
    ///
    /// - Parameter bytes: The borrowed bytes containing the UUID.
    /// - Returns: An identifier when the bytes contain a valid UUID; otherwise
    ///   `nil`.
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
    ///
    /// - Parameter value: The literal to copy into bounded storage.
    /// - Returns: A type identifier, or `nil` when the literal exceeds the
    ///   bounded capacity.
    public init?(_ value: StaticString) {
        let count = value.utf8CodeUnitCount
        guard count <= Self.capacity else { return nil }
        storage = InlineArray(repeating: 0)
        length = count
        for index in 0..<count { storage[index] = value.utf8Start[index] }
    }

    /// Copies a borrowed UTF-8 type identifier into bounded storage.
    ///
    /// - Parameter bytes: The borrowed bytes to copy.
    /// - Returns: A type identifier, or `nil` when the bytes exceed capacity.
    public init?(bytes: ByteSlice) {
        guard bytes.length <= Self.capacity else { return nil }
        storage = InlineArray(repeating: 0)
        length = bytes.length
        for index in 0..<bytes.length { storage[index] = bytes.byte(at: index)! }
    }

    /// Compares the type against a static UTF-8 literal without allocation.
    ///
    /// - Parameter value: The static type spelling to compare.
    /// - Returns: `true` when the bounded bytes match exactly.
    public func equals(_ value: StaticString) -> Bool {
        guard length == value.utf8CodeUnitCount else { return false }
        for index in 0..<length where storage[index] != value.utf8Start[index] { return false }
        return true
    }

    /// Compares two object types by their bounded UTF-8 bytes.
    ///
    /// - Parameters:
    ///   - lhs: The first object type.
    ///   - rhs: The second object type.
    /// - Returns: `true` when both identifiers contain identical bytes.
    public static func == (lhs: ObjectType, rhs: ObjectType) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }

    /// Adds the bounded UTF-8 bytes to a hasher.
    ///
    /// - Parameter hasher: The hasher receiving this type's identity.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(length)
        for index in 0..<length { hasher.combine(storage[index]) }
    }
}

extension ObjectType: ObjectFieldEncodable {
    /// Encodes this bounded object type as a JSON string field.
    public borrowing func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        let localStorage = storage
        let localLength = length
        var failure: ObjectError?
        withUnsafeBytes(of: localStorage) { buffer in
            let bytes = ByteSlice(
                bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                length: localLength
            )
            do throws(ObjectError) { try editor.setEncodedString(key, value: bytes) }
            catch { failure = error }
        }
        if let failure { throw failure.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

/// A bounded owned JSON-string-content byte value used for common metadata.
/// Escape sequences are retained exactly; this type does not claim Unicode decoding.
public struct BoundedEncodedText<let capacity: Int>: Equatable, Hashable, Sendable {
    private var storage: InlineArray<capacity, UInt8>
    /// Number of meaningful bytes.
    public private(set) var length: Int

    /// Copies UTF-8 bytes from a borrowed wire slice.
    ///
    /// - Parameter bytes: The borrowed encoded string bytes.
    /// - Returns: A bounded value, or `nil` when the bytes exceed capacity.
    public init?(bytes: ByteSlice) {
        guard bytes.length <= capacity else { return nil }
        storage = InlineArray(repeating: 0); length = bytes.length
        for index in 0..<length { storage[index] = bytes.byte(at: index)! }
    }

    /// Creates bounded text from a static UTF-8 literal.
    ///
    /// - Parameter value: The literal to copy into bounded storage.
    /// - Returns: A bounded value, or `nil` when the literal exceeds capacity.
    public init?(_ value: StaticString) {
        guard value.utf8CodeUnitCount <= capacity else { return nil }
        storage = InlineArray(repeating: 0); length = value.utf8CodeUnitCount
        for index in 0..<length { storage[index] = value.utf8Start[index] }
    }

    /// Compares the retained encoded JSON-string content with a static value.
    ///
    /// - Parameter value: The static encoded string to compare.
    /// - Returns: `true` when the retained bytes match exactly.
    public borrowing func encodedEquals(_ value: StaticString) -> Bool {
        guard length == value.utf8CodeUnitCount else { return false }
        for index in 0..<length where storage[index] != value.utf8Start[index] { return false }
        return true
    }

    /// Encodes this retained string into a transactional object editor.
    ///
    /// - Parameters:
    ///   - key: The bounded wire key for the string.
    ///   - editor: The transactional editor receiving the string.
    /// - Throws: ``ObjectError`` when the string is invalid or the editor has
    ///   insufficient capacity.
    public borrowing func encodeField<let editorCapacity: Int>(
        _ key: StaticString,
        to editor: inout ObjectEditor<editorCapacity>
    ) throws(ObjectError) {
        let localLength = length
        let localStorage = storage
        var failure: ObjectError?
        withUnsafeBytes(of: localStorage) { buffer in
            let bytes = ByteSlice(
                bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                length: localLength
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
    ///
    /// - Parameters:
    ///   - key: The bounded wire key for the string.
    ///   - writer: The writer receiving the encoded field.
    /// - Throws: ``WireEncodeError`` when the writer rejects the field.
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

    /// Compares two bounded text values by their retained encoded bytes.
    ///
    /// - Parameters:
    ///   - lhs: The first text value.
    ///   - rhs: The second text value.
    /// - Returns: `true` when both values contain identical bytes.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }

    /// Adds the retained encoded bytes to a hasher.
    ///
    /// - Parameter hasher: The hasher receiving this value's identity.
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

extension ObjectCoreType: ObjectFieldEncodable {
    /// Encodes the canonical Coaty core spelling as a JSON string field.
    public func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        func set(_ value: StaticString) throws(ObjectEncodingError) {
            do {
                try editor.setEncodedString(key, value: ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount))
            } catch {
                throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField
            }
        }
        switch self {
        case .coatyObject: try set("CoatyObject")
        case .user: try set("User")
        case .annotation: try set("Annotation")
        case .task: try set("Task")
        case .ioSource: try set("IoSource")
        case .ioActor: try set("IoActor")
        case .ioNode: try set("IoNode")
        case .ioContext: try set("IoContext")
        case .identity: try set("Identity")
        case .log: try set("Log")
        case .location: try set("Location")
        case .snapshot: try set("Snapshot")
        case .unknown(let value): try value.encode(to: &editor, forKey: key)
        }
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
extension Presence: Equatable where Value: Equatable {}
