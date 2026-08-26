// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The lexical kind of a borrowed JSON value.
public enum JSONValueKind: UInt8, Sendable, Equatable {
    /// An object value.
    case object
    /// An array value.
    case array
    /// A quoted string value.
    case string
    /// A JSON number.
    case number
    /// `true`.
    case trueValue
    /// `false`.
    case falseValue
    /// `null`.
    case null
    /// No value was available.
    case invalid
}

/// A borrowed JSON number retaining its exact source lexeme.
public struct JSONNumberView: ~Copyable {
    @usableFromInline let lexeme: ByteSlice

    /// Creates a borrowed number view.
    @usableFromInline init(lexeme: ByteSlice) { self.lexeme = lexeme }

    /// Compares the retained source lexeme without exposing borrowed storage.
    public borrowing func lexemeEquals(_ value: StaticString) -> Bool { lexeme.equals(value) }

    /// A checked signed integer conversion; fractional and exponent forms are rejected.
    public var intValue: Int64? { parseInteger(negativeAllowed: true) }
    /// A checked unsigned integer conversion; negative and fractional forms are rejected.
    public var uintValue: UInt64? { parseUnsigned() }
    /// A finite floating-point conversion retaining the original lexeme separately.
    public var doubleValue: Double? { parseDouble() }

    private func parseInteger(negativeAllowed: Bool) -> Int64? {
        guard isValidNumber(), lexeme.length > 0 else { return nil }
        var index = 0; var negative = false
        if lexeme.byte(at: 0) == 45 { negative = true; index = 1 }
        guard !negative || negativeAllowed, index < lexeme.length else { return nil }
        var result: Int64 = 0
        while index < lexeme.length {
            guard let byte = lexeme.byte(at: index), byte >= 48, byte <= 57 else { return nil }
            let (next, overflow) = result.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            let (final, digitOverflow) = negative
                ? next.subtractingReportingOverflow(Int64(byte - 48))
                : next.addingReportingOverflow(Int64(byte - 48))
            guard !digitOverflow else { return nil }
            result = final; index += 1
        }
        return result
    }

    private func parseUnsigned() -> UInt64? {
        guard isValidNumber(), lexeme.length > 0 else { return nil }
        var result: UInt64 = 0
        for index in 0..<lexeme.length {
            guard let byte = lexeme.byte(at: index), byte >= 48, byte <= 57 else { return nil }
            let (next, overflow) = result.multipliedReportingOverflow(by: 10)
            let (final, digitOverflow) = next.addingReportingOverflow(UInt64(byte - 48))
            guard !overflow && !digitOverflow else { return nil }
            result = final
        }
        return result
    }

    private func parseDouble() -> Double? {
        guard isValidNumber(), lexeme.length > 0 else { return nil }
        var index = 0; var negative = false
        if lexeme.byte(at: 0) == 45 { negative = true; index += 1 }
        guard index < lexeme.length else { return nil }
        var integer: Double = 0; var sawDigit = false
        while index < lexeme.length, let byte = lexeme.byte(at: index), byte >= 48, byte <= 57 {
            integer = integer * 10 + Double(byte - 48); index += 1; sawDigit = true
        }
        var fraction: Double = 0; var divisor: Double = 1
        if index < lexeme.length, lexeme.byte(at: index) == 46 {
            index += 1
            while index < lexeme.length, let byte = lexeme.byte(at: index), byte >= 48, byte <= 57 {
                fraction = fraction * 10 + Double(byte - 48); divisor *= 10; index += 1; sawDigit = true
            }
        }
        guard sawDigit else { return nil }
        var exponent = 0
        if index < lexeme.length, lexeme.byte(at: index) == 101 || lexeme.byte(at: index) == 69 {
            index += 1; var exponentNegative = false
            if index < lexeme.length, lexeme.byte(at: index) == 45 { exponentNegative = true; index += 1 }
            else if index < lexeme.length, lexeme.byte(at: index) == 43 { index += 1 }
            var exponentDigits = 0
            while index < lexeme.length, let byte = lexeme.byte(at: index), byte >= 48, byte <= 57 {
                let nextExponent = exponent * 10 + Int(byte - 48)
                guard nextExponent <= 1024 else { return nil }
                exponent = nextExponent; index += 1; exponentDigits += 1
            }
            guard exponentDigits > 0 else { return nil }
            if exponentNegative { exponent = -exponent }
        }
        guard index == lexeme.length else { return nil }
        let value = (integer + fraction / divisor) * pow10(exponent)
        guard value.isFinite else { return nil }
        guard value != 0 || integer == 0 && fraction == 0 else { return nil }
        return negative ? -value : value
    }

    private func isValidNumber() -> Bool {
        guard lexeme.length > 0 else { return false }
        var index = 0
        if lexeme.byte(at: index) == 45 { index += 1 }
        guard index < lexeme.length else { return false }
        if lexeme.byte(at: index) == 48 {
            index += 1
            if index < lexeme.length, lexeme.byte(at: index)! >= 48, lexeme.byte(at: index)! <= 57 { return false }
        } else {
            guard let first = lexeme.byte(at: index), first >= 49, first <= 57 else { return false }
            repeat { index += 1 } while index < lexeme.length && lexeme.byte(at: index)! >= 48 && lexeme.byte(at: index)! <= 57
        }
        if index < lexeme.length, lexeme.byte(at: index) == 46 {
            index += 1; let start = index
            while index < lexeme.length, lexeme.byte(at: index)! >= 48, lexeme.byte(at: index)! <= 57 { index += 1 }
            guard index > start else { return false }
        }
        if index < lexeme.length, lexeme.byte(at: index) == 101 || lexeme.byte(at: index) == 69 {
            index += 1
            if index < lexeme.length, lexeme.byte(at: index) == 45 || lexeme.byte(at: index) == 43 { index += 1 }
            let start = index
            while index < lexeme.length, lexeme.byte(at: index)! >= 48, lexeme.byte(at: index)! <= 57 { index += 1 }
            guard index > start else { return false }
        }
        return index == lexeme.length
    }

    private func pow10(_ exponent: Int) -> Double {
        if exponent == 0 { return 1 }
        var result: Double = 1
        if exponent > 0 { for _ in 0..<exponent { result *= 10 } }
        else { for _ in 0..<(-exponent) { result /= 10 } }
        return result
    }
}

/// A synchronous borrowed view into one JSON value in an object arena.
public struct JSONValueView: ~Copyable {
    @usableFromInline let raw: ByteSlice
    /// The lexical kind of this value.
    public let kind: JSONValueKind

    init(raw: ByteSlice) {
        self.raw = raw
        guard let firstByte = raw.byte(at: 0) else { kind = .invalid; return }
        switch firstByte {
        case 123: kind = .object
        case 91: kind = .array
        case 34: kind = .string
        case 116: kind = .trueValue
        case 102: kind = .falseValue
        case 110: kind = .null
        case 45, 48...57: kind = .number
        default: kind = .invalid
        }
    }

    /// Validates one complete borrowed JSON value and visits its view.
    ///
    /// The view and its bytes are valid only during `body`; callers must
    /// materialize owned state before returning from the visitor.
    ///
    /// - Parameters:
    ///   - raw: Complete borrowed JSON bytes.
    ///   - body: Nonescaping synchronous visitor.
    /// - Returns: The visitor result.
    /// - Throws: ``ObjectError`` when `raw` is not one valid JSON value.
    public static func withValidatedRaw<R>(
        _ raw: borrowing ByteSlice,
        _ body: (borrowing JSONValueView) -> R
    ) throws(ObjectError) -> R {
        guard WireReader.isValidJSONValue(raw) else {
            throw ObjectError(.invalidField)
        }
        return body(JSONValueView(raw: raw))
    }

    /// Returns the number view when this value is numeric.
    /// Borrows the number view only for the duration of `body`.
    public borrowing func withNumber(_ body: (borrowing JSONNumberView) -> Void) -> Bool {
        guard kind == .number else { return false }
        body(JSONNumberView(lexeme: raw)); return true
    }
    /// Borrows encoded JSON-string content for the duration of `body`.
    public borrowing func withString(_ body: (borrowing ByteSlice) -> Void) -> Bool {
        guard kind == .string, raw.length >= 2 else { return false }
        body(raw.subSlice(from: 1, length: raw.length - 2)); return true
    }
    /// Returns true when the value is the JSON null literal.
    public var isNull: Bool { kind == .null }

    /// Compares the exact retained value bytes without exposing borrowed storage.
    public borrowing func rawEquals(_ value: StaticString) -> Bool { raw.equals(value) }

    /// Borrows the complete encoded value for the duration of `body`.
    public borrowing func withRaw(_ body: (ByteSlice) -> Void) { body(raw) }

    /// Decodes a nested bounded object schema from this JSON object value.
    ///
    /// The nested schema is decoded synchronously while the borrowed value is
    /// valid. Callers receive an owned, copyable schema value.
    public borrowing func decode<Schema: ObjectSchema>(
        _ type: Schema.Type
    ) throws(ObjectDecodingError) -> Schema {
        guard kind == .object else { throw .invalidField }
        var result: Schema?
        var failure: ObjectDecodingError?
        raw.withBytes { pointer, length in
            do throws(ObjectDecodingError) {
                result = try Schema(decoding: ObjectFieldDecoder(
                    bytes: pointer,
                    length: length
                ))
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        guard let result else { throw .invalidField }
        return result
    }
}

/// An owned, bounded JSON value snapshot that can safely outlive its source object.
public struct OwnedJSONValue<let byteCapacity: Int>: Sendable, Equatable {
    private var storage: InlineArray<byteCapacity, UInt8>
    private var length: Int

    /// Copies one complete JSON value into inline storage.
    public init(copying value: ByteSlice) throws(ObjectError) {
        guard value.length <= byteCapacity else { throw ObjectError(.capacityExceeded, byteOffset: value.length) }
        guard WireReader.isValidJSONValue(value) else { throw ObjectError(.invalidEditValue) }
        storage = InlineArray(repeating: 0); length = value.length
        for index in 0..<value.length { storage[index] = value.byte(at: index)! }
    }

    @usableFromInline
    init(copying view: borrowing JSONValueView) throws(ObjectError) {
        try self.init(copying: view.raw)
    }

    /// Compares this owned snapshot against a static value.
    public borrowing func encodedEquals(_ value: StaticString) -> Bool {
        let localLength = length
        let localStorage = storage
        return withUnsafeBytes(of: localStorage) { bytes in
            ByteSlice(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), length: localLength).equals(value)
        }
    }

    /// Borrows the complete retained JSON value for the duration of `body`.
    ///
    /// The returned bytes remain owned by this value and must not escape the
    /// synchronous borrow. Callers that cross an async or isolation boundary
    /// must copy them into their own bounded storage first.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        let localLength = length
        let localStorage = storage
        return try withUnsafeBytes(of: localStorage) { bytes in
            try body(ByteSlice(
                bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                length: localLength
            ))
        }
    }

    /// Borrows this snapshot's view for the duration of `body`.
    public borrowing func withView(_ body: (borrowing JSONValueView) -> Void) {
        let localLength = length
        let localStorage = storage
        withUnsafeBytes(of: localStorage) { bytes in
            body(JSONValueView(raw: ByteSlice(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), length: localLength)))
        }
    }

    /// Compares two owned values byte-for-byte, preserving their source
    /// number lexemes and JSON formatting.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.storage[index] != rhs.storage[index] {
            return false
        }
        return true
    }
}

/// A small, allocation-free edit literal encoded without Foundation.
public enum JSONValue {
    /// Encodes JSON null.
    case null
    /// Encodes a static string literal with JSON quotes and escapes.
    case string(StaticString)
    /// Encodes a static number lexeme after validating it as JSON.
    case number(StaticString)
    /// Encodes JSON true or false.
    case bool(Bool)
}
