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
    ///
    /// Inputs larger than ``WireBufferConfig.maxPayloadSize`` are rejected
    /// before tokenizer workspace is initialized. Accepted inputs use a
    /// fixed-size tokenizer workspace with eight guard bytes; indexed values
    /// continue to borrow from the caller's original buffer.
    public init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.bytes = UnsafeRawPointer(bytes); self.length = max(0, length)
        let buffer = UnsafeBufferPointer(start: bytes, count: max(0, length))
        var index = FieldIndex()
        guard buffer.count <= WireBufferConfig.maxPayloadSize else {
            index.failure = WireDecodeError(.payloadExceedsLimit, byteOffset: buffer.count)
            self.index = index
            return
        }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxPayloadSize + 8) { padded in
            if buffer.count > 0 {
                padded.baseAddress!.initialize(from: buffer.baseAddress!, count: buffer.count)
            }
            for offset in buffer.count..<(buffer.count + 8) { padded[offset] = 0x7D }
            let paddedBuffer = UnsafeBufferPointer(start: padded.baseAddress!, count: buffer.count + 8)
            var destination = FieldDestination(bytes: buffer)
            var tokenizer = JSONTokenizer(bytes: paddedBuffer, destination: destination)
            do {
                try tokenizer.scanValue()
            } catch {
                tokenizer.destination.failure = Self.parserFailure(
                    buffer,
                    offset: tokenizer.currentOffset,
                    destination: tokenizer.destination,
                    parserError: error
                )
            }
            destination = tokenizer.destination
            if destination.failure == nil && tokenizer.currentOffset > buffer.count {
                destination.failure = WireDecodeError(.unexpectedEndOfInput, byteOffset: buffer.count)
            } else {
                var offset = tokenizer.currentOffset
                while offset < buffer.count && Self.isWhitespace(buffer[offset]) { offset += 1 }
                if destination.failure == nil && offset != buffer.count {
                    destination.failure = WireDecodeError(
                        .unexpectedToken(expected: "end of input", actual: buffer[offset]),
                        byteOffset: offset
                    )
                }
            }
            index = destination.index
        }
        self.index = index
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
            guard count > 0, count <= WireBufferConfig.maxPayloadSize else { return false }
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
        guard index.failure == nil, let range = index.find(bytes: bytes, key: key) else { return nil }
        return slice(range.value)
    }

    /// Returns string content without quotes. The returned bytes retain JSON
    /// escape sequences and must be treated as encoded string content.
    public func readString(_ key: StaticString) -> ByteSlice? {
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key), slot.kind == .string else { return nil }
        return slice(slot.content)
    }

    /// Reads a canonical JSON UUID string.
    public func readUUID(_ key: StaticString) -> UUID16? { readString(key).flatMap(UUID16.init(parsing:)) }

    /// Reads a JSON integer, rejecting other token kinds and overflow.
    public func readInt(_ key: StaticString) -> Int? {
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key), slot.kind == .number,
              let value = slice(slot.value) else { return nil }
        var result = 0; var negative = false; var offset = 0
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
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key) else { return nil }
        if slot.kind == .trueValue { return true }; if slot.kind == .falseValue { return false }; return nil
    }

    /// Reads a complete raw JSON value, including quotes for strings.
    public func readRaw(_ key: StaticString) -> ByteSlice? { readField(key) }

    /// Reads an optional raw value, treating an explicit JSON `null` as absent.
    public func readOptionalRaw(_ key: StaticString) -> ByteSlice? {
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key), slot.kind != .nullValue else { return nil }
        return slice(slot.value)
    }

    @inline(__always) private func slice(_ range: Range<Int>) -> ByteSlice? {
        guard range.lowerBound >= 0, range.lowerBound <= range.upperBound, range.upperBound <= length else { return nil }
        return ByteSlice(pointer: bytes.advanced(by: range.lowerBound), length: range.count)
    }
    @inline(__always) private static func isWhitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }

    @usableFromInline struct FieldSlot {
        let key: Range<Int>; let value: Range<Int>; let content: Range<Int>; let kind: WireTokenKind
    }

    @usableFromInline struct FieldIndex {
        var rootObject = false; var completeValue = false; var failure: WireDecodeError?; var count = 0
        var slots = (FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none, FieldSlot?.none)
        func slot(_ n: Int) -> FieldSlot? { switch n { case 0: slots.0; case 1: slots.1; case 2: slots.2; case 3: slots.3; case 4: slots.4; case 5: slots.5; case 6: slots.6; case 7: slots.7; case 8: slots.8; case 9: slots.9; case 10: slots.10; case 11: slots.11; case 12: slots.12; case 13: slots.13; case 14: slots.14; case 15: slots.15; case 16: slots.16; case 17: slots.17; case 18: slots.18; case 19: slots.19; case 20: slots.20; case 21: slots.21; case 22: slots.22; case 23: slots.23; default: nil } }
        func find(bytes: UnsafeRawPointer, key: StaticString) -> FieldSlot? { for n in 0..<count { if let value = slot(n), value.key.count == key.utf8CodeUnitCount { var equal = true; for i in 0..<value.key.count where bytes.load(fromByteOffset: value.key.lowerBound + i, as: UInt8.self) != key.utf8Start[i] { equal = false; break }; if equal { return value } } }; return nil }
        mutating func append(_ value: FieldSlot, bytes: UnsafeBufferPointer<UInt8>) {
            guard isBounded(value.key, bytes: bytes), isBounded(value.value, bytes: bytes), isBounded(value.content, bytes: bytes) else {
                if failure == nil { failure = WireDecodeError(.unexpectedEndOfInput, byteOffset: bytes.count) }
                return
            }
            for n in 0..<count {
                if let prior = slot(n), prior.key.count == value.key.count {
                    var equal = true
                    for i in 0..<value.key.count where bytes[prior.key.lowerBound + i] != bytes[value.key.lowerBound + i] {
                        equal = false
                        break
                    }
                    if equal {
                        if failure == nil { failure = WireDecodeError(.duplicateField, byteOffset: value.key.lowerBound) }
                        return
                    }
                }
            }
            guard count < WireBufferConfig.maxIndexedFields else {
                failure = WireDecodeError(.fieldIndexOverflow, byteOffset: value.key.lowerBound)
                return
            }
            switch count {
            case 0: slots.0 = value; case 1: slots.1 = value; case 2: slots.2 = value; case 3: slots.3 = value
            case 4: slots.4 = value; case 5: slots.5 = value; case 6: slots.6 = value; case 7: slots.7 = value
            case 8: slots.8 = value; case 9: slots.9 = value; case 10: slots.10 = value; case 11: slots.11 = value
            case 12: slots.12 = value; case 13: slots.13 = value; case 14: slots.14 = value; case 15: slots.15 = value
            case 16: slots.16 = value; case 17: slots.17 = value; case 18: slots.18 = value; case 19: slots.19 = value
            case 20: slots.20 = value; case 21: slots.21 = value; case 22: slots.22 = value; case 23: slots.23 = value
            default: break
            }
            count += 1
        }
        private func isBounded(_ range: Range<Int>, bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            range.lowerBound >= 0 && range.lowerBound <= range.upperBound && range.upperBound <= bytes.count
        }
    }

    private struct Context { let start: Int; let key: Range<Int>? }
    private struct FieldDestination: JSONTokenizerDestination {
        typealias ArrayStartContext = Context; typealias ObjectStartContext = Context
        let bytes: UnsafeBufferPointer<UInt8>
        var index = FieldIndex()
        var depth = 0
        var pendingKey: Range<Int>?
        var expectingKey = false
        var containerCount = 0
        var containers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))

        mutating func objectStartFound(_ token: JSONToken.ObjectStart) -> Context {
            if depth == 0 { index.rootObject = true; expectingKey = true }
            if depth >= 8 { record(.init(.invalidNesting, byteOffset: token.start.byteOffset)) }
            pushContainer(0x7B)
            let context = Context(start: token.start.byteOffset, key: depth == 1 ? pendingKey : nil)
            pendingKey = nil
            depth += 1
            return context
        }

        mutating func objectEndFound(_ token: JSONToken.ObjectEnd, context: consuming Context) {
            depth -= 1
            popContainer()
            if depth == 1, let key = context.key {
                index.append(FieldSlot(key: key, value: context.start..<token.end.byteOffset, content: context.start..<token.end.byteOffset, kind: .object), bytes: bytes)
                expectingKey = true
            }
            if depth == 0 { index.completeValue = true; expectingKey = false }
        }

        mutating func arrayStartFound(_ token: JSONToken.ArrayStart) -> Context {
            if depth >= 8 { record(.init(.invalidNesting, byteOffset: token.start.byteOffset)) }
            pushContainer(0x5B)
            let context = Context(start: token.start.byteOffset, key: depth == 1 ? pendingKey : nil)
            pendingKey = nil
            depth += 1
            return context
        }

        mutating func arrayEndFound(_ token: JSONToken.ArrayEnd, context: consuming Context) {
            depth -= 1
            popContainer()
            if depth == 1, let key = context.key {
                index.append(FieldSlot(key: key, value: context.start..<token.end.byteOffset, content: context.start..<token.end.byteOffset, kind: .array), bytes: bytes)
                expectingKey = true
            }
            if depth == 0 { index.completeValue = true }
        }

        mutating func stringFound(_ token: JSONToken.String) {
            let raw = token.start.byteOffset..<token.end.byteOffset
            if let failure = validateString(raw) { record(failure) }
            let content = raw.lowerBound < raw.upperBound && bytes[raw.lowerBound] == 0x22 ? raw.lowerBound + 1..<raw.upperBound - 1 : raw
            if depth == 1 && expectingKey { pendingKey = content; expectingKey = false }
            else { value(raw, content, .string) }
        }

        mutating func numberFound(_ token: JSONToken.Number) {
            let raw = token.start.byteOffset..<token.end.byteOffset
            if let failure = validateNumber(raw) { record(failure) }
            value(raw, raw, .number)
        }

        mutating func booleanTrueFound(_ token: JSONToken.BooleanTrue) { let raw = token.start.byteOffset - 4..<token.start.byteOffset; value(raw, raw, .trueValue) }
        mutating func booleanFalseFound(_ token: JSONToken.BooleanFalse) { let raw = token.start.byteOffset - 5..<token.start.byteOffset; value(raw, raw, .falseValue) }
        mutating func nullFound(_ token: JSONToken.Null) { let raw = token.start.byteOffset - 4..<token.start.byteOffset; value(raw, raw, .nullValue) }

        mutating func value(_ raw: Range<Int>, _ content: Range<Int>, _ kind: WireTokenKind) {
            if depth == 0 { index.completeValue = true; return }
            guard depth == 1, let key = pendingKey else { return }
            index.append(FieldSlot(key: key, value: raw, content: content, kind: kind), bytes: bytes)
            pendingKey = nil
            expectingKey = true
            index.completeValue = true
        }

        mutating func record(_ error: WireDecodeError) {
            if index.failure == nil { index.failure = error }
        }

        mutating func pushContainer(_ kind: UInt8) {
            switch containerCount {
            case 0: containers.0 = kind
            case 1: containers.1 = kind
            case 2: containers.2 = kind
            case 3: containers.3 = kind
            case 4: containers.4 = kind
            case 5: containers.5 = kind
            case 6: containers.6 = kind
            case 7: containers.7 = kind
            default: break
            }
            containerCount += 1
        }

        mutating func popContainer() {
            if containerCount > 0 { containerCount -= 1 }
        }

        var topContainer: UInt8? {
            switch containerCount {
            case 1: containers.0
            case 2: containers.1
            case 3: containers.2
            case 4: containers.3
            case 5: containers.4
            case 6: containers.5
            case 7: containers.6
            case 8: containers.7
            default: nil
            }
        }

        func validateString(_ range: Range<Int>) -> WireDecodeError? {
            guard range.count >= 2 else { return .init(.unexpectedEndOfInput, byteOffset: range.lowerBound) }
            let end = range.upperBound - 1
            var offset = range.lowerBound + 1
            while offset < end {
                let byte = bytes[offset]
                if byte == 0x5C {
                    let escapeOffset = offset
                    offset += 1
                    guard offset < end else { return .init(.invalidEscape, byteOffset: escapeOffset) }
                    if bytes[offset] == 0x75 {
                        guard let high = unicodeEscape(at: offset, before: end) else { return .init(.invalidEscape, byteOffset: offset) }
                        offset += 5
                        if high >= 0xD800 && high <= 0xDBFF {
                            guard offset + 5 < end, bytes[offset] == 0x5C, bytes[offset + 1] == 0x75,
                                  let low = unicodeEscape(at: offset + 1, before: end), low >= 0xDC00, low <= 0xDFFF
                            else { return .init(.invalidEscape, byteOffset: escapeOffset) }
                            offset += 6
                        } else if high >= 0xDC00 && high <= 0xDFFF {
                            return .init(.invalidEscape, byteOffset: escapeOffset)
                        }
                    } else {
                        switch bytes[offset] {
                        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: offset += 1
                        default: return .init(.invalidEscape, byteOffset: offset)
                        }
                    }
                } else if byte < 0x20 {
                    return .init(.invalidEscape, byteOffset: offset)
                } else {
                    let width: Int
                    if byte < 0x80 { width = 1 }
                    else if byte >= 0xC2 && byte <= 0xDF { width = 2 }
                    else if byte >= 0xE0 && byte <= 0xEF { width = 3 }
                    else if byte >= 0xF0 && byte <= 0xF4 { width = 4 }
                    else { return .init(.invalidUTF8, byteOffset: offset) }
                    guard offset + width <= end else { return .init(.invalidUTF8, byteOffset: offset) }
                    if width > 1 {
                        let second = bytes[offset + 1]
                        guard !((byte == 0xE0 && second < 0xA0) || (byte == 0xED && second > 0x9F) || (byte == 0xF0 && second < 0x90) || (byte == 0xF4 && second > 0x8F)) else {
                            return .init(.invalidUTF8, byteOffset: offset)
                        }
                        for continuation in 1..<width {
                            guard bytes[offset + continuation] >= 0x80 && bytes[offset + continuation] <= 0xBF else {
                                return .init(.invalidUTF8, byteOffset: offset + continuation)
                            }
                        }
                    }
                    offset += width
                }
            }
            return nil
        }

        func unicodeEscape(at offset: Int, before end: Int) -> Int? {
            guard offset + 4 < end else { return nil }
            var value = 0
            for digitOffset in 1...4 {
                let byte = bytes[offset + digitOffset]
                let digit: Int
                if byte >= 48 && byte <= 57 { digit = Int(byte - 48) }
                else if byte >= 65 && byte <= 70 { digit = Int(byte - 55) }
                else if byte >= 97 && byte <= 102 { digit = Int(byte - 87) }
                else { return nil }
                value = value * 16 + digit
            }
            return value
        }

        func validateNumber(_ range: Range<Int>) -> WireDecodeError? {
            var offset = range.lowerBound
            if bytes[offset] == 0x2D { offset += 1 }
            guard offset < range.upperBound else { return .init(.invalidNumber, byteOffset: range.lowerBound) }
            if bytes[offset] == 0x30 {
                offset += 1
                if offset < range.upperBound, bytes[offset] >= 0x30 && bytes[offset] <= 0x39 { return .init(.invalidNumber, byteOffset: offset) }
            } else {
                guard bytes[offset] >= 0x31 && bytes[offset] <= 0x39 else { return .init(.invalidNumber, byteOffset: offset) }
                while offset < range.upperBound && bytes[offset] >= 0x30 && bytes[offset] <= 0x39 { offset += 1 }
            }
            if offset < range.upperBound, bytes[offset] == 0x2E {
                offset += 1
                guard offset < range.upperBound, bytes[offset] >= 0x30 && bytes[offset] <= 0x39 else { return .init(.invalidNumber, byteOffset: offset) }
                while offset < range.upperBound && bytes[offset] >= 0x30 && bytes[offset] <= 0x39 { offset += 1 }
            }
            if offset < range.upperBound, bytes[offset] == 0x65 || (offset < range.upperBound && bytes[offset] == 0x45) {
                offset += 1
                if offset < range.upperBound && (bytes[offset] == 0x2B || bytes[offset] == 0x2D) { offset += 1 }
                guard offset < range.upperBound, bytes[offset] >= 0x30 && bytes[offset] <= 0x39 else { return .init(.invalidNumber, byteOffset: offset) }
                while offset < range.upperBound && bytes[offset] >= 0x30 && bytes[offset] <= 0x39 { offset += 1 }
            }
            return offset == range.upperBound ? nil : .init(.invalidNumber, byteOffset: offset)
        }

        var failure: WireDecodeError? { get { index.failure } set { index.failure = newValue } }
    }

    private static func parserFailure(
        _ bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        destination: FieldDestination,
        parserError: Error
    ) -> WireDecodeError {
        if let failure = destination.failure { return failure }
        if let parserError = parserError as? JSONParserError, case .missingData = parserError {
            return .init(.unexpectedEndOfInput, byteOffset: bytes.count)
        }
        guard offset < bytes.count else { return .init(.unexpectedEndOfInput, byteOffset: bytes.count) }
        let byte = bytes[offset]
        if byte == 0x74 || byte == 0x66 || byte == 0x6E { return .init(.invalidLiteral, byteOffset: offset) }
        if byte == 0x2D || byte >= 0x30 && byte <= 0x39 { return .init(.invalidNumber, byteOffset: offset) }
        if (byte == 0x7D && destination.topContainer != 0x7B) || (byte == 0x5D && destination.topContainer != 0x5B) {
            return .init(.invalidNesting, byteOffset: offset)
        }
        return .init(.unexpectedToken(expected: "valid JSON", actual: byte), byteOffset: offset)
    }
}
