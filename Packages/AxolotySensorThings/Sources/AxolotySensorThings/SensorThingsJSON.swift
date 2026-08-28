// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

/// A bounded JSON value used by SensorThings metadata, results, parameters,
/// and heterogeneous Thing properties.
///
/// The value keeps its original encoded representation. In particular, JSON
/// numbers are not converted through `Double`, and the value is never wrapped
/// in a JSON string when it is placed in an object field.
public struct SensorThingsJSONValue: Sendable, Equatable, ObjectFieldDecodable, ObjectFieldEncodable {
    private let value: OwnedJSONValue<2048>

    /// Copies one complete JSON value into bounded storage.
    ///
    /// - Parameter value: The borrowed JSON bytes to copy.
    /// - Throws: ``ObjectError`` when the value is malformed or exceeds the
    ///   SensorThings field bound.
    public init(copying value: ByteSlice) throws(ObjectError) {
        self.value = try OwnedJSONValue<2048>(copying: value)
    }

    /// Creates a value from a static JSON literal.
    ///
    /// - Parameter literal: A complete JSON value, including quotes for a
    ///   string literal.
    /// - Throws: ``ObjectError`` when the literal is invalid or too large.
    public init(_ literal: StaticString) throws(ObjectError) {
        try self.init(copying: ByteSlice(
            bytes: literal.utf8Start,
            length: literal.utf8CodeUnitCount
        ))
    }

    /// Returns the lexical JSON kind without exposing borrowed storage.
    public var kind: JSONValueKind {
        var result: JSONValueKind = .invalid
        value.withView { result = $0.kind }
        return result
    }

    /// Compares the exact retained bytes against a static JSON literal.
    public borrowing func encodedEquals(_ literal: StaticString) -> Bool {
        value.encodedEquals(literal)
    }

    /// Borrows the retained JSON bytes for synchronous inspection.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try value.withEncodedBytes(body)
    }

    /// Returns the number view when this value is a JSON number.
    public borrowing func withNumber(_ body: (borrowing JSONNumberView) -> Void) -> Bool {
        var result = false
        value.withView { view in result = view.withNumber(body) }
        return result
    }

    /// Copies one borrowed JSON value into the bounded representation.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var result: Self?
        value.withRaw { raw in result = try? Self(copying: raw) }
        guard let result else { throw .invalidField }
        return result
    }

    /// Encodes the value as raw JSON, preserving its original representation.
    public borrowing func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        var failure: ObjectError?
        value.withEncodedBytes { raw in
            do throws(ObjectError) { try editor.setRaw(key, value: raw) }
            catch { failure = error }
        }
        if let failure {
            throw failure.reason == .capacityExceeded ? .capacityExceeded : .invalidField
        }
    }
}

/// A bounded JSON number retaining its source lexeme.
public struct SensorThingsNumber: Sendable, Equatable, ObjectFieldDecodable, ObjectFieldEncodable {
    private let value: OwnedJSONValue<64>

    /// Copies a JSON number into bounded storage.
    public init(copying value: ByteSlice) throws(ObjectError) {
        let owned = try OwnedJSONValue<64>(copying: value)
        var kind: JSONValueKind = .invalid
        owned.withView { kind = $0.kind }
        guard kind == .number else { throw ObjectError(.invalidEditValue) }
        self.value = owned
    }

    /// Creates a number from a static JSON number literal.
    public init(_ literal: StaticString) throws(ObjectError) {
        try self.init(copying: ByteSlice(
            bytes: literal.utf8Start,
            length: literal.utf8CodeUnitCount
        ))
    }

    /// Returns an exact integer conversion when the retained lexeme is one.
    public var int64: Int64? {
        var result: Int64?
        value.withView { _ = $0.withNumber { result = $0.intValue } }
        return result
    }

    /// Returns a finite floating-point conversion when representable.
    public var double: Double? {
        var result: Double?
        value.withView { _ = $0.withNumber { result = $0.doubleValue } }
        return result
    }

    /// Borrows the retained source lexeme.
    public borrowing func encodedEquals(_ literal: StaticString) -> Bool {
        value.encodedEquals(literal)
    }

    /// Borrows the retained source lexeme.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try value.withEncodedBytes(body)
    }

    /// Decodes a JSON number without normalizing its source spelling.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        guard value.kind == .number else { throw .invalidField }
        var result: Self?
        value.withRaw { raw in result = try? Self(copying: raw) }
        guard let result else { throw .invalidField }
        return result
    }

    /// Encodes the retained number as a raw JSON field value.
    public borrowing func encode<let editorCapacity: Int>(
        to editor: inout ObjectFieldEncoder<editorCapacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        var failure: ObjectError?
        value.withEncodedBytes { raw in
            do throws(ObjectError) { try editor.setRaw(key, value: raw) }
            catch { failure = error }
        }
        if let failure {
            throw failure.reason == .capacityExceeded ? .capacityExceeded : .invalidField
        }
    }
}
