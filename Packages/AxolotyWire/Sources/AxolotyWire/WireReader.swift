// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A Foundation-free, zero-allocation JSON reader for typed field access.
///
/// Scans a JSON byte buffer in-place, looking up fields by key and returning
/// borrowed `ByteSlice` values for strings and raw JSON. No intermediate
/// JSON value tree, dictionary, or Codable reflection is constructed.
///
/// Designed for the wire decode hot path where the JSON shape is known at
/// compile time (e.g. an `AssociateEvent` has `ioSourceId`, `ioActorId`,
/// `associatingRoute`, etc.). The caller reads fields by static string key.
///
/// - Important: When constructed from ``BorrowedMessage``, use the reader and
///   its returned ``ByteSlice`` values only in the message's synchronous
///   borrow scope. Copy data before an `await` or another isolation-domain hop.
public struct WireReader {
    /// The raw pointer to the JSON byte buffer being scanned.
    @usableFromInline let bytes: UnsafeRawPointer
    /// The number of valid bytes pointed to by ``bytes``.
    public let length: Int

    /// Creates a reader over the given JSON byte buffer.
    ///
    /// The reader holds the pointer without copying; the caller must ensure
    /// the buffer remains valid for the reader's lifetime.
    ///
    /// - Parameters:
    ///   - bytes: A pointer to the UTF-8 JSON bytes to scan.
    ///   - length: The number of valid bytes at `bytes`.
    @inlinable
    public init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.bytes = UnsafeRawPointer(bytes)
        self.length = length
    }

    // MARK: - Object field access

    /// Finds a top-level field by key and returns its value bytes as a ByteSlice.
    ///
    /// For string values, the returned slice excludes the surrounding quotes.
    /// For non-string values (numbers, objects, arrays, booleans, null), the
    /// raw JSON bytes are returned.
    public func readField(_ key: StaticString) -> ByteSlice? {
        let keyLen = key.utf8CodeUnitCount
        var pos = skipWhitespace(0)
        guard pos < length, bytes.load(fromByteOffset: pos, as: UInt8.self) == 0x7B else {
            return nil // not an object
        }
        pos += 1 // skip '{'

        while pos < length {
            pos = skipWhitespace(pos)
            guard pos < length, bytes.load(fromByteOffset: pos, as: UInt8.self) == 0x22 else {
                return nil // expected '"'
            }
            pos += 1 // skip opening '"'

            // Read key
            let keyStart = pos
            while pos < length {
                let b = bytes.load(fromByteOffset: pos, as: UInt8.self)
                if b == 0x22 { break } // closing '"'
                if b == 0x5C { pos += 2; continue } // skip escaped char
                pos += 1
            }
            guard pos < length else { return nil }
            let keyEnd = pos
            pos += 1 // skip closing '"'

            // Compare key
            let fieldLen = keyEnd - keyStart
            let isMatch = fieldLen == keyLen && compareBytes(
                bytes.advanced(by: keyStart), key.utf8Start, keyLen
            )

            pos = skipWhitespace(pos)
            guard pos < length, bytes.load(fromByteOffset: pos, as: UInt8.self) == 0x3A else {
                return nil // expected ':'
            }
            pos += 1 // skip ':'
            pos = skipWhitespace(pos)

            if isMatch {
                return readValue(at: &pos)
            } else {
                skipValue(at: &pos)
                pos = skipWhitespace(pos)
                if pos < length {
                    let b = bytes.load(fromByteOffset: pos, as: UInt8.self)
                    if b == 0x2C { pos += 1; continue } // ','
                    if b == 0x7D { break } // '}'
                }
                return nil
            }
        }
        return nil
    }

    // MARK: - Typed accessors

    /// Reads a string field, returning the value bytes (without quotes).
    public func readString(_ key: StaticString) -> ByteSlice? {
        guard let slice = readField(key) else { return nil }
        return hasValidEscapes(slice) && hasValidUTF8(slice) ? slice : nil
    }

    /// Reads a UUID field, returning a fixed 16-byte UUID.
    public func readUUID(_ key: StaticString) -> UUID16? {
        guard let slice = readField(key) else { return nil }
        return UUID16(parsing: slice)
    }

    /// Reads an integer field.
    public func readInt(_ key: StaticString) -> Int? {
        guard let slice = readField(key) else { return nil }
        var value: Int = 0
        var negative = false
        var i = 0
        if i < slice.length && slice.byte(at: i) == 0x2D { // '-'
            negative = true
            i += 1
        }
        let firstDigit = i
        while i < slice.length {
            guard let b = slice.byte(at: i), b >= 0x30 && b <= 0x39 else { return nil }
            let digit = Int(b - 0x30)
            // Accumulate toward the sign so Int.min stays representable.
            let (product, prodOverflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, sumOverflow) = negative
                ? product.subtractingReportingOverflow(digit)
                : product.addingReportingOverflow(digit)
            guard !prodOverflow, !sumOverflow else { return nil }
            value = sum
            i += 1
        }
        guard i > firstDigit else { return nil }
        return value
    }

    /// Reads a boolean field.
    public func readBool(_ key: StaticString) -> Bool? {
        guard let slice = readField(key) else { return nil }
        if slice.equals("true") { return true }
        if slice.equals("false") { return false }
        return nil
    }

    /// Reads a raw JSON value (the complete JSON bytes for a field, useful
    /// for opaque/payload values that should be preserved without decoding).
    public func readRaw(_ key: StaticString) -> ByteSlice? {
        readField(key)
    }

    // MARK: - Internal scanning

    @inline(__always)
    private func skipWhitespace(_ pos: Int) -> Int {
        var p = pos
        while p < length {
            let b = bytes.load(fromByteOffset: p, as: UInt8.self)
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                p += 1
            } else {
                break
            }
        }
        return p
    }

    @inline(__always)
    private func compareBytes(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ count: Int) -> Bool {
        for i in 0..<count {
            if a.load(fromByteOffset: i, as: UInt8.self) != b.load(fromByteOffset: i, as: UInt8.self) {
                return false
            }
        }
        return true
    }

    /// Validates JSON escape sequences in a borrowed string slice.
    private func hasValidEscapes(_ slice: ByteSlice) -> Bool {
        var index = 0
        while index < slice.length {
            guard let byte = slice.byte(at: index), byte >= 0x20 else { return false }
            guard byte == 0x5C else {
                index += 1
                continue
            }
            index += 1
            guard let escaped = slice.byte(at: index) else { return false }
            switch escaped {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                index += 1
            case 0x75:
                guard index + 4 < slice.length else { return false }
                for offset in 1...4 {
                    guard let hex = slice.byte(at: index + offset),
                          (hex >= 0x30 && hex <= 0x39) ||
                          (hex >= 0x41 && hex <= 0x46) ||
                          (hex >= 0x61 && hex <= 0x66)
                    else { return false }
                }
                index += 5
            default:
                return false
            }
        }
        return true
    }

    /// Validates that a borrowed string slice contains well-formed UTF-8.
    private func hasValidUTF8(_ slice: ByteSlice) -> Bool {
        var index = 0
        while index < slice.length {
            guard let lead = slice.byte(at: index) else { return false }
            if lead < 0x80 {
                index += 1
                continue
            }
            let continuationCount: Int
            switch lead {
            case 0xC2...0xDF: continuationCount = 1
            case 0xE0...0xEF: continuationCount = 2
            case 0xF0...0xF4: continuationCount = 3
            default: return false
            }
            guard index + continuationCount < slice.length else { return false }
            for offset in 1...continuationCount {
                guard let continuation = slice.byte(at: index + offset),
                      continuation >= 0x80, continuation <= 0xBF
                else { return false }
            }
            index += continuationCount + 1
        }
        return true
    }

    /// Reads a JSON value starting at `pos` and advances `pos` past it.
    /// Returns the value bytes (for strings, without quotes).
    private func readValue(at pos: inout Int) -> ByteSlice? {
        guard pos < length else { return nil }
        let b = bytes.load(fromByteOffset: pos, as: UInt8.self)

        switch b {
        case 0x22: // '"' — string value
            pos += 1
            let start = pos
            while pos < length {
                let c = bytes.load(fromByteOffset: pos, as: UInt8.self)
                if c == 0x5C {
                    guard pos + 1 < length else { return nil }
                    pos += 2
                    continue
                }
                if c == 0x22 { break } // closing quote
                pos += 1
            }
            guard pos < length else { return nil }
            let end = pos
            pos += 1 // skip closing quote
            return ByteSlice(pointer: bytes.advanced(by: start), length: end - start)

        case 0x7B: // '{' — object
            return scanBalanced(&pos, open: 0x7B, close: 0x7D)

        case 0x5B: // '[' — array
            return scanBalanced(&pos, open: 0x5B, close: 0x5D)

        case 0x74: // 't' — true
            let start = pos
            let end = min(pos + 4, length)
            pos = end
            return ByteSlice(pointer: bytes.advanced(by: start), length: end - start)

        case 0x66: // 'f' — false
            let start = pos
            let end = min(pos + 5, length)
            pos = end
            return ByteSlice(pointer: bytes.advanced(by: start), length: end - start)

        case 0x6E: // 'n' — null
            let start = pos
            let end = min(pos + 4, length)
            pos = end
            return ByteSlice(pointer: bytes.advanced(by: start), length: end - start)

        default: // number
            let start = pos
            while pos < length {
                let c = bytes.load(fromByteOffset: pos, as: UInt8.self)
                if c == 0x2C || c == 0x7D || c == 0x5D || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    break
                }
                pos += 1
            }
            return ByteSlice(pointer: bytes.advanced(by: start), length: pos - start)
        }
    }

    /// Scans a balanced bracket pair (object or array), returning the full
    /// byte range including the opening and closing brackets.
    private func scanBalanced(_ pos: inout Int, open: UInt8, close: UInt8) -> ByteSlice {
        let start = pos
        var depth = 0
        var inString = false
        while pos < length {
            let b = bytes.load(fromByteOffset: pos, as: UInt8.self)
            if inString {
                if b == 0x5C { pos += 2; continue }
                if b == 0x22 { inString = false }
            } else {
                if b == 0x22 { inString = true }
                else if b == open { depth += 1 }
                else if b == close {
                    depth -= 1
                    if depth == 0 { pos += 1; break }
                }
            }
            pos += 1
        }
        return ByteSlice(pointer: bytes.advanced(by: start), length: pos - start)
    }

    /// Skips a JSON value at `pos` without returning its bytes.
    private func skipValue(at pos: inout Int) {
        _ = readValue(at: &pos)
    }
}
