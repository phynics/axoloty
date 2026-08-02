// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

/// The lexical kind retained for an indexed JSON value.
@usableFromInline enum WireTokenKind: UInt8 { case object, array, string, number, trueValue, falseValue, nullValue }

/// A Foundation-free reader which tokenizes once into bounded borrowed slots.
public struct WireReader {
    @usableFromInline let bytes: UnsafeRawPointer
    public let length: Int
    @usableFromInline let index: FieldIndex

    /// Creates a reader over a borrowed JSON byte buffer.
    public init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.bytes = UnsafeRawPointer(bytes); self.length = max(0, length)
        let buffer = UnsafeBufferPointer(start: bytes, count: max(0, length))
        var destination = FieldDestination(bytes: buffer)
        if let lexicalFailure = Self.preflight(buffer) {
            destination.failure = lexicalFailure
        } else {
            var tokenizer = JSONTokenizer(bytes: buffer, destination: destination)
            do { try tokenizer.scanValue() }
            catch { destination.failure = WireDecodeError(.unexpectedToken(expected: "valid JSON", actual: nil), byteOffset: tokenizer.currentOffset) }
            destination = tokenizer.destination
            var offset = tokenizer.currentOffset
            while offset < buffer.count && Self.isWhitespace(buffer[offset]) { offset += 1 }
            if destination.failure == nil && offset != buffer.count { destination.failure = WireDecodeError(.unexpectedToken(expected: "end of input", actual: buffer[offset]), byteOffset: offset) }
        }
        self.index = destination.index
    }

    /// Validates that the complete input is one JSON object.
    public func validate() throws(WireDecodeError) {
        if let failure = index.failure { throw failure }
        guard index.rootObject else { throw WireDecodeError(.typeMismatch(expected: "object")) }
    }

    /// Returns whether the complete input is one JSON value.
    public static func isValidJSON(_ bytes: ByteSlice) -> Bool { isValidJSONValue(bytes) }

    /// Returns whether the complete input is one JSON value, including scalars.
    public static func isValidJSONValue(_ bytes: ByteSlice) -> Bool {
        bytes.withBytes { pointer, count in
            guard count > 0 else { return false }
            if Int(bitPattern: pointer) % MemoryLayout<UInt64>.alignment != 0 {
                guard count <= WireBufferConfig.maxPayloadSize else { return false }
                var alignedStorage = SIMD64<UInt64>(repeating: 0)
                return withUnsafeMutableBytes(of: &alignedStorage) { storage in
                    for offset in 0..<count {
                        storage[offset] = pointer.load(fromByteOffset: offset, as: UInt8.self)
                    }
                    let aligned = storage.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let reader = WireReader(bytes: aligned, length: count)
                    return reader.index.failure == nil && reader.index.completeValue
                }
            }
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
            return reader.index.failure == nil && reader.index.completeValue
        }
    }

    /// Returns the complete raw JSON value for a top-level key.
    public func readField(_ key: StaticString) -> ByteSlice? {
        guard let range = index.find(bytes: bytes, key: key) else { return nil }
        return slice(range.value)
    }

    /// Returns string content without quotes. The returned bytes retain JSON
    /// escape sequences and must be treated as encoded string content.
    public func readString(_ key: StaticString) -> ByteSlice? {
        guard let slot = index.find(bytes: bytes, key: key), slot.kind == .string else { return nil }
        return slice(slot.content)
    }

    /// Reads a canonical JSON UUID string.
    public func readUUID(_ key: StaticString) -> UUID16? { readString(key).flatMap(UUID16.init(parsing:)) }

    /// Reads a JSON integer, rejecting other token kinds and overflow.
    public func readInt(_ key: StaticString) -> Int? {
        guard let slot = index.find(bytes: bytes, key: key), slot.kind == .number else { return nil }
        let value = slice(slot.value); var result = 0; var negative = false; var offset = 0
        if value.byte(at: 0) == 0x2D { negative = true; offset = 1 }
        let first = offset
        while offset < value.length {
            guard let byte = value.byte(at: offset), byte >= 48 && byte <= 57 else { return nil }
            let (product, productOverflow) = result.multipliedReportingOverflow(by: 10)
            let (next, digitOverflow) = negative ? product.subtractingReportingOverflow(Int(byte - 48)) : product.addingReportingOverflow(Int(byte - 48))
            guard !productOverflow && !digitOverflow else { return nil }
            result = next; offset += 1
        }
        return offset == first ? nil : result
    }

    /// Reads a JSON boolean, rejecting other token kinds.
    public func readBool(_ key: StaticString) -> Bool? {
        guard let slot = index.find(bytes: bytes, key: key) else { return nil }
        if slot.kind == .trueValue { return true }; if slot.kind == .falseValue { return false }; return nil
    }

    /// Reads a complete raw JSON value, including quotes for strings.
    public func readRaw(_ key: StaticString) -> ByteSlice? { readField(key) }

    /// Reads an optional raw value, treating an explicit JSON `null` as absent.
    public func readOptionalRaw(_ key: StaticString) -> ByteSlice? {
        guard let slot = index.find(bytes: bytes, key: key), slot.kind != .nullValue else { return nil }
        return slice(slot.value)
    }

    @inline(__always) private func slice(_ range: Range<Int>) -> ByteSlice { ByteSlice(pointer: bytes.advanced(by: range.lowerBound), length: range.count) }
    @inline(__always) private static func isWhitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }

    @usableFromInline struct FieldSlot {
        let key: Range<Int>; let value: Range<Int>; let content: Range<Int>; let kind: WireTokenKind
    }

    @usableFromInline struct FieldIndex {
        var rootObject = false; var completeValue = false; var failure: WireDecodeError?; var count = 0
        var slots = (FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none)
        func slot(_ n: Int) -> FieldSlot? { switch n { case 0: slots.0; case 1: slots.1; case 2: slots.2; case 3: slots.3; case 4: slots.4; case 5: slots.5; case 6: slots.6; case 7: slots.7; case 8: slots.8; case 9: slots.9; case 10: slots.10; case 11: slots.11; case 12: slots.12; case 13: slots.13; case 14: slots.14; case 15: slots.15; case 16: slots.16; case 17: slots.17; case 18: slots.18; case 19: slots.19; case 20: slots.20; case 21: slots.21; case 22: slots.22; case 23: slots.23; default: nil } }
        func find(bytes: UnsafeRawPointer, key: StaticString) -> FieldSlot? { for n in 0..<count { if let value = slot(n), value.key.count == key.utf8CodeUnitCount { var equal = true; for i in 0..<value.key.count where bytes.load(fromByteOffset: value.key.lowerBound + i, as: UInt8.self) != key.utf8Start[i] { equal = false; break }; if equal { return value } } }; return nil }
        mutating func append(_ value: FieldSlot, bytes: UnsafeBufferPointer<UInt8>) { for n in 0..<count { if let prior = slot(n), prior.key.count == value.key.count { var equal = true; for i in 0..<value.key.count where bytes[prior.key.lowerBound + i] != bytes[value.key.lowerBound + i] { equal = false; break }; if equal { if failure == nil { failure = WireDecodeError(.duplicateField, byteOffset: value.key.lowerBound) }; return } } }; guard count < WireBufferConfig.maxIndexedFields else { failure = WireDecodeError(.fieldIndexOverflow, byteOffset: value.key.lowerBound); return }; switch count { case 0: slots.0 = value; case 1: slots.1 = value; case 2: slots.2 = value; case 3: slots.3 = value; case 4: slots.4 = value; case 5: slots.5 = value; case 6: slots.6 = value; case 7: slots.7 = value; case 8: slots.8 = value; case 9: slots.9 = value; case 10: slots.10 = value; case 11: slots.11 = value; case 12: slots.12 = value; case 13: slots.13 = value; case 14: slots.14 = value; case 15: slots.15 = value; case 16: slots.16 = value; case 17: slots.17 = value; case 18: slots.18 = value; case 19: slots.19 = value; case 20: slots.20 = value; case 21: slots.21 = value; case 22: slots.22 = value; case 23: slots.23 = value; default: break }; count += 1 }
    }

    private struct Context { let start: Int; let key: Range<Int>? }
    private struct FieldDestination: JSONTokenizerDestination {
        typealias ArrayStartContext = Context; typealias ObjectStartContext = Context
        let bytes: UnsafeBufferPointer<UInt8>; var index = FieldIndex(); var depth = 0; var pendingKey: Range<Int>?; var expectingKey = false
        mutating func objectStartFound(_ token: JSONToken.ObjectStart) -> Context { if depth == 0 { index.rootObject = true; expectingKey = true }; let context = Context(start: token.start.byteOffset, key: depth == 1 ? pendingKey : nil); pendingKey = nil; depth += 1; return context }
        mutating func objectEndFound(_ token: JSONToken.ObjectEnd, context: consuming Context) { depth -= 1; if depth == 1, let key = context.key { index.append(FieldSlot(key: key, value: context.start..<token.end.byteOffset, content: context.start..<token.end.byteOffset, kind: .object), bytes: bytes); expectingKey = true }; if depth == 0 { index.completeValue = true; expectingKey = false } }
        mutating func arrayStartFound(_ token: JSONToken.ArrayStart) -> Context { let context = Context(start: token.start.byteOffset, key: depth == 1 ? pendingKey : nil); pendingKey = nil; depth += 1; return context }
        mutating func arrayEndFound(_ token: JSONToken.ArrayEnd, context: consuming Context) { depth -= 1; if depth == 1, let key = context.key { index.append(FieldSlot(key: key, value: context.start..<token.end.byteOffset, content: context.start..<token.end.byteOffset, kind: .array), bytes: bytes); expectingKey = true }; if depth == 0 { index.completeValue = true } }
        mutating func stringFound(_ token: JSONToken.String) { let raw = token.start.byteOffset..<token.end.byteOffset; let content = raw.lowerBound < raw.upperBound && bytes[raw.lowerBound] == 0x22 ? raw.lowerBound + 1..<raw.upperBound - 1 : raw; if depth == 1 && expectingKey { pendingKey = content; expectingKey = false } else { value(raw, content, .string) } }
        mutating func numberFound(_ token: JSONToken.Number) { value(token.start.byteOffset..<token.end.byteOffset, token.start.byteOffset..<token.end.byteOffset, .number) }
        mutating func booleanTrueFound(_ token: JSONToken.BooleanTrue) { let raw = token.start.byteOffset - 4..<token.start.byteOffset; value(raw, raw, .trueValue) }
        mutating func booleanFalseFound(_ token: JSONToken.BooleanFalse) { let raw = token.start.byteOffset - 5..<token.start.byteOffset; value(raw, raw, .falseValue) }
        mutating func nullFound(_ token: JSONToken.Null) { let raw = token.start.byteOffset - 4..<token.start.byteOffset; value(raw, raw, .nullValue) }
        mutating func value(_ raw: Range<Int>, _ content: Range<Int>, _ kind: WireTokenKind) { if depth == 0 { index.completeValue = true; return }; guard depth == 1, let key = pendingKey else { return }; index.append(FieldSlot(key: key, value: raw, content: content, kind: kind), bytes: bytes); pendingKey = nil; expectingKey = true; index.completeValue = true }
        var failure: WireDecodeError? { get { index.failure } set { index.failure = newValue } }
    }

    // Strict lexical completion necessarily dispatches every JSON token class.
    // swiftlint:disable:next cyclomatic_complexity
    private static func preflight(_ bytes: UnsafeBufferPointer<UInt8>) -> WireDecodeError? {
        var stack = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)); var stackCount = 0; var depth = 0; var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) { index += 1; continue }
            switch byte {
            case 0x22:
                if let failure = scanString(bytes, index: &index) { return failure }
            case 0x7B, 0x5B:
                guard stackCount < 8 else { return WireDecodeError(.invalidNesting, byteOffset: index) }
                switch stackCount { case 0: stack.0 = byte; case 1: stack.1 = byte; case 2: stack.2 = byte; case 3: stack.3 = byte; case 4: stack.4 = byte; case 5: stack.5 = byte; case 6: stack.6 = byte; default: stack.7 = byte }
                stackCount += 1; depth += 1; index += 1
            case 0x7D, 0x5D:
                guard stackCount > 0 else { return WireDecodeError(.invalidNesting, byteOffset: index) }
                let top: UInt8; switch stackCount { case 1: top = stack.0; case 2: top = stack.1; case 3: top = stack.2; case 4: top = stack.3; case 5: top = stack.4; case 6: top = stack.5; case 7: top = stack.6; default: top = stack.7 }
                guard byte == 0x7D ? top == 0x7B : top == 0x5B else { return WireDecodeError(.invalidNesting, byteOffset: index) }
                stackCount -= 1; depth -= 1; index += 1
            case 0x74: guard literal(bytes, index: index, length: 4, first: (0x74, 0x72, 0x75, 0x65, 0)) else { return WireDecodeError(.invalidLiteral, byteOffset: index) }; index += 4
            case 0x66: guard literal(bytes, index: index, length: 5, first: (0x66, 0x61, 0x6C, 0x73, 0x65)) else { return WireDecodeError(.invalidLiteral, byteOffset: index) }; index += 5
            case 0x6E: guard literal(bytes, index: index, length: 4, first: (0x6E, 0x75, 0x6C, 0x6C, 0)) else { return WireDecodeError(.invalidLiteral, byteOffset: index) }; index += 4
            case 0x2D, 0x30...0x39: guard scanNumber(bytes, index: &index) else { return WireDecodeError(.invalidNumber, byteOffset: index) }
            case 0x2C, 0x3A: index += 1
            default: return WireDecodeError(.unexpectedToken(expected: "JSON token", actual: byte), byteOffset: index)
            }
            guard depth <= 8 else { return WireDecodeError(.invalidNesting, byteOffset: index) }
        }
        guard stackCount == 0 && depth == 0 else { return WireDecodeError(.unexpectedEndOfInput, byteOffset: bytes.count) }
        return nil
    }

    private static func scanString(_ bytes: UnsafeBufferPointer<UInt8>, index: inout Int) -> WireDecodeError? {
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 { index += 1; return nil }
            if byte == 0x5C {
                index += 1; guard index < bytes.count else { return WireDecodeError(.invalidEscape, byteOffset: index - 1) }
                let escape = bytes[index]
                if escape == 0x75 {
                    guard index + 4 < bytes.count, let code = hex4(bytes, index + 1) else { return WireDecodeError(.invalidEscape, byteOffset: index) }
                    index += 5
                    if code >= 0xD800 && code <= 0xDBFF { guard index + 5 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75, let low = hex4(bytes, index + 2), low >= 0xDC00 && low <= 0xDFFF else { return WireDecodeError(.invalidEscape, byteOffset: index) }; index += 6 }
                    else if code >= 0xDC00 && code <= 0xDFFF { return WireDecodeError(.invalidEscape, byteOffset: index - 5) }
                } else { guard escape == 0x22 || escape == 0x5C || escape == 0x2F || escape == 0x62 || escape == 0x66 || escape == 0x6E || escape == 0x72 || escape == 0x74 else { return WireDecodeError(.invalidEscape, byteOffset: index) }; index += 1 }
            } else if byte < 0x20 { return WireDecodeError(.invalidEscape, byteOffset: index) }
            else { let width: Int; if byte < 0x80 { width = 1 } else if byte >= 0xC2 && byte <= 0xDF { width = 2 } else if byte >= 0xE0 && byte <= 0xEF { width = 3 } else if byte >= 0xF0 && byte <= 0xF4 { width = 4 } else { return WireDecodeError(.invalidUTF8, byteOffset: index) }; guard index + width <= bytes.count else { return WireDecodeError(.invalidUTF8, byteOffset: index) }; if width > 1 { let second = bytes[index + 1]; if (byte == 0xE0 && second < 0xA0) || (byte == 0xED && second > 0x9F) || (byte == 0xF0 && second < 0x90) || (byte == 0xF4 && second > 0x8F) { return WireDecodeError(.invalidUTF8, byteOffset: index) } }; for offset in 1..<width { guard bytes[index + offset] >= 0x80 && bytes[index + offset] <= 0xBF else { return WireDecodeError(.invalidUTF8, byteOffset: index + offset) } }; index += width }
        }
        return WireDecodeError(.unexpectedEndOfInput, byteOffset: bytes.count)
    }

    private static func scanNumber(_ bytes: UnsafeBufferPointer<UInt8>, index: inout Int) -> Bool {
        if bytes[index] == 0x2D { index += 1; guard index < bytes.count else { return false } }
        if bytes[index] == 0x30 { index += 1; if index < bytes.count && isDigit(bytes[index]) { return false } }
        else { guard index < bytes.count && bytes[index] >= 0x31 && bytes[index] <= 0x39 else { return false }; while index < bytes.count && isDigit(bytes[index]) { index += 1 } }
        if index < bytes.count && bytes[index] == 0x2E { index += 1; guard index < bytes.count && isDigit(bytes[index]) else { return false }; while index < bytes.count && isDigit(bytes[index]) { index += 1 } }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) { index += 1; if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }; guard index < bytes.count && isDigit(bytes[index]) else { return false }; while index < bytes.count && isDigit(bytes[index]) { index += 1 } }
        return true
    }

    private static func literal(_ bytes: UnsafeBufferPointer<UInt8>, index: Int, length: Int, first: (UInt8, UInt8, UInt8, UInt8, UInt8)) -> Bool { guard index + length <= bytes.count else { return false }; for offset in 0..<length { let expected: UInt8; switch offset { case 0: expected = first.0; case 1: expected = first.1; case 2: expected = first.2; case 3: expected = first.3; default: expected = first.4 }; if bytes[index + offset] != expected { return false } }; return true }
    private static func hex4(_ bytes: UnsafeBufferPointer<UInt8>, _ index: Int) -> Int? { guard index + 4 <= bytes.count else { return nil }; var value = 0; for offset in 0..<4 { let byte = bytes[index + offset]; let digit: Int; if byte >= 48 && byte <= 57 { digit = Int(byte - 48) } else if byte >= 65 && byte <= 70 { digit = Int(byte - 55) } else if byte >= 97 && byte <= 102 { digit = Int(byte - 87) } else { return nil }; value = value * 16 + digit }; return value }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
}
