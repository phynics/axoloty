// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The semantic-tag allow-list a ``CBORReader`` accepts.
///
/// Deterministic CBOR forbids tags outside a profile's allow-list because an
/// unknown tag changes how the tagged value must be interpreted. The
/// `axoloty/1` profile allows only the UUID tag (37) and the epoch-time tag (1).
public enum CBORTagPolicy: Sendable, Equatable {
    /// The `axoloty/1` allow-list: UUID (37) and epoch time (1).
    case profile
    /// Rejects every semantic tag.
    case none

    /// Returns whether the policy accepts the given tag number.
    ///
    /// - Parameter tag: The CBOR tag number.
    public func allows(_ tag: UInt64) -> Bool {
        switch self {
        case .none:
            return false
        case .profile:
            return tag == 37 || tag == 1
        }
    }
}

/// A bounded, allocation-free, deterministic CBOR (RFC 8949) reader.
///
/// The reader walks a caller-owned byte buffer without copying or allocating.
/// It enforces the `axoloty/1` core deterministic rules:
///
/// * definite lengths only; indefinite-length items are rejected
/// * shortest-form arguments; non-minimal integers and lengths are rejected
/// * semantic tags restricted to the configured ``CBORTagPolicy``
/// * containers bounded by ``WireBufferConfig/maxCBORNestingDepth``
/// * duplicate map keys rejected for text, byte-string, and integer keys
///
/// The reader borrows its backing bytes. Keep it and every ``ByteSlice`` it
/// returns inside the caller's synchronous buffer scope: do not cross `await`,
/// create a `Task`, hop to an actor, or capture the reader in an escaping
/// closure. Copy data before any such hop.
public struct CBORReader: ~Sendable {
    /// The raw pointer to the CBOR byte buffer.
    @usableFromInline let bytes: UnsafePointer<UInt8>
    /// The number of valid bytes pointed to by ``bytes``.
    public let byteCount: Int
    /// The current read offset into the buffer.
    public private(set) var offset: Int
    /// The maximum container nesting this reader accepts.
    public let maximumDepth: Int
    /// The semantic-tag allow-list.
    public let tagPolicy: CBORTagPolicy
    /// The maximum byte-string or text-string length this reader accepts.
    public let maximumStringLength: Int

    /// Creates a reader over a caller-owned CBOR byte buffer.
    ///
    /// - Parameters:
    ///   - bytes: A pointer to the CBOR bytes.
    ///   - length: The number of valid bytes at `bytes`.
    ///   - maximumDepth: Maximum container nesting. Defaults to
    ///     ``WireBufferConfig/maxCBORNestingDepth``.
    ///   - tagPolicy: The semantic-tag allow-list. Defaults to the
    ///     `axoloty/1` profile allow-list.
    ///   - maximumStringLength: Maximum string length in bytes. Defaults to
    ///     ``WireBufferConfig/maxPayloadSize``.
    public init(
        bytes: UnsafePointer<UInt8>,
        length: Int,
        maximumDepth: Int = WireBufferConfig.maxCBORNestingDepth,
        tagPolicy: CBORTagPolicy = .profile,
        maximumStringLength: Int = WireBufferConfig.maxPayloadSize
    ) {
        self.bytes = bytes
        self.byteCount = max(0, length)
        self.offset = 0
        self.maximumDepth = max(0, maximumDepth)
        self.tagPolicy = tagPolicy
        self.maximumStringLength = max(0, maximumStringLength)
    }

    /// Whether the reader has consumed every input byte.
    public var isAtEnd: Bool { offset >= byteCount }

    /// The number of unread bytes.
    public var remaining: Int { max(0, byteCount - offset) }
}

extension CBORReader {
    // MARK: - Head parsing

    @inline(__always)
    private mutating func readInitial() throws(WireDecodeError) -> (major: UInt8, additional: UInt8, start: Int) {
        let start = offset
        guard offset < byteCount else {
            throw WireDecodeError(.unexpectedEndOfInput, byteOffset: start)
        }
        let initial = bytes[offset]
        offset += 1
        return (initial >> 5, initial & 0x1F, start)
    }

    @inline(__always)
    private mutating func readBigEndian(_ count: Int) throws(WireDecodeError) -> UInt64 {
        guard count >= 0, offset + count <= byteCount else {
            throw WireDecodeError(.unexpectedEndOfInput, byteOffset: offset)
        }
        var value: UInt64 = 0
        for index in 0..<count {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        offset += count
        return value
    }

    private mutating func readArgument(
        major: UInt8, additional: UInt8, start: Int
    ) throws(WireDecodeError) -> UInt64 {
        switch additional {
        case 0...23:
            return UInt64(additional)
        case 24:
            let value = try readBigEndian(1)
            guard value >= 24 else {
                throw WireDecodeError(.cborNonMinimalInteger, byteOffset: start)
            }
            return value
        case 25:
            let value = try readBigEndian(2)
            guard value > 0xFF else {
                throw WireDecodeError(.cborNonMinimalInteger, byteOffset: start)
            }
            return value
        case 26:
            let value = try readBigEndian(4)
            guard value > 0xFFFF else {
                throw WireDecodeError(.cborNonMinimalInteger, byteOffset: start)
            }
            return value
        case 27:
            let value = try readBigEndian(8)
            guard value > 0xFFFF_FFFF else {
                throw WireDecodeError(.cborNonMinimalInteger, byteOffset: start)
            }
            return value
        case 31:
            throw WireDecodeError(.cborIndefiniteLength, byteOffset: start)
        default:
            throw WireDecodeError(.cborInvalidAdditionalInfo, byteOffset: start)
        }
    }

    private mutating func readHead(major expected: UInt8) throws(WireDecodeError) -> UInt64 {
        let (major, additional, start) = try readInitial()
        guard major == expected else {
            throw WireDecodeError(.cborUnexpectedMajorType(expected: expected), byteOffset: start)
        }
        return try readArgument(major: major, additional: additional, start: start)
    }

    // MARK: - Integers

    /// Reads an unsigned integer (CBOR major type 0).
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a minimally encoded
    ///   unsigned integer.
    public mutating func readUnsigned() throws(WireDecodeError) -> UInt64 {
        try readHead(major: 0)
    }

    /// Reads a negative integer (CBOR major type 1) as `-1 - n`.
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a minimally encoded
    ///   negative integer or the result overflows `Int64`.
    public mutating func readNegative() throws(WireDecodeError) -> Int64 {
        let start = offset
        let value = try readHead(major: 1)
        guard value <= UInt64(Int64.max) else {
            throw WireDecodeError(.integerOverflow, byteOffset: start)
        }
        return -1 - Int64(value)
    }

    /// Reads an integer of either sign (CBOR major type 0 or 1).
    ///
    /// - Throws: ``WireDecodeError`` when the item is not an integer or the
    ///   value overflows `Int64`.
    public mutating func readInteger() throws(WireDecodeError) -> Int64 {
        let start = offset
        let (major, additional, _) = try readInitial()
        switch major {
        case 0:
            let value = try readArgument(major: major, additional: additional, start: start)
            guard value <= UInt64(Int64.max) else {
                throw WireDecodeError(.integerOverflow, byteOffset: start)
            }
            return Int64(value)
        case 1:
            let value = try readArgument(major: major, additional: additional, start: start)
            guard value <= UInt64(Int64.max) else {
                throw WireDecodeError(.integerOverflow, byteOffset: start)
            }
            return -1 - Int64(value)
        default:
            throw WireDecodeError(.cborUnexpectedMajorType(expected: 0), byteOffset: start)
        }
    }

    // MARK: - Strings

    /// Reads a definite-length byte string (CBOR major type 2).
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a byte string, the
    ///   declared length exceeds ``maximumStringLength``, or the input ends
    ///   early.
    public mutating func readByteString() throws(WireDecodeError) -> ByteSlice {
        try readString(major: 2)
    }

    /// Reads a definite-length text string (CBOR major type 3).
    ///
    /// The returned bytes are validated as UTF-8.
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a text string, the
    ///   declared length exceeds ``maximumStringLength``, the bytes are not
    ///   valid UTF-8, or the input ends early.
    public mutating func readTextString() throws(WireDecodeError) -> ByteSlice {
        let slice = try readString(major: 3)
        guard Self.isValidUTF8(slice) else {
            throw WireDecodeError(.invalidUTF8, byteOffset: offset - slice.length)
        }
        return slice
    }

    private mutating func readString(major: UInt8) throws(WireDecodeError) -> ByteSlice {
        let start = offset
        let length = try readHead(major: major)
        guard length <= UInt64(maximumStringLength) else {
            throw WireDecodeError(.payloadExceedsLimit, byteOffset: start)
        }
        let count = Int(length)
        guard offset + count <= byteCount else {
            throw WireDecodeError(.unexpectedEndOfInput, byteOffset: offset)
        }
        let slice = ByteSlice(pointer: bytes.advanced(by: offset), length: count)
        offset += count
        return slice
    }

    // MARK: - Simple values

    /// Reads a boolean (CBOR simple values 20 and 21).
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a boolean.
    public mutating func readBool() throws(WireDecodeError) -> Bool {
        let (major, additional, start) = try readInitial()
        guard major == 7 else {
            throw WireDecodeError(.cborUnexpectedMajorType(expected: 7), byteOffset: start)
        }
        switch additional {
        case 20: return false
        case 21: return true
        default:
            throw WireDecodeError(.cborUnexpectedMajorType(expected: 7), byteOffset: start)
        }
    }

    /// Reads and validates a CBOR null (simple value 22).
    ///
    /// - Throws: ``WireDecodeError`` when the item is not null.
    public mutating func readNull() throws(WireDecodeError) {
        let (major, additional, start) = try readInitial()
        guard major == 7, additional == 22 else {
            throw WireDecodeError(.cborUnexpectedMajorType(expected: 7), byteOffset: start)
        }
    }

    // MARK: - Containers

    /// Reads an array header (CBOR major type 4) and returns its item count.
    ///
    /// - Throws: ``WireDecodeError`` when the item is not an array or the
    ///   count overflows `Int`.
    public mutating func readArrayHeader() throws(WireDecodeError) -> Int {
        try readCount(major: 4)
    }

    /// Reads a map header (CBOR major type 5) and returns its pair count.
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a map or the count
    ///   overflows `Int`.
    public mutating func readMapHeader() throws(WireDecodeError) -> Int {
        try readCount(major: 5)
    }

    private mutating func readCount(major: UInt8) throws(WireDecodeError) -> Int {
        let start = offset
        let value = try readHead(major: major)
        guard value <= UInt64(Int.max) else {
            throw WireDecodeError(.integerOverflow, byteOffset: start)
        }
        return Int(value)
    }

    // MARK: - Tags

    /// Reads a semantic tag (CBOR major type 6) and validates it against the
    /// tag policy.
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a tag or the tag is
    ///   outside the allow-list.
    public mutating func readTag() throws(WireDecodeError) -> UInt64 {
        let start = offset
        let tag = try readHead(major: 6)
        guard tagPolicy.allows(tag) else {
            throw WireDecodeError(.cborUnsupportedTag, byteOffset: start)
        }
        return tag
    }

    /// Reads a UUID encoded as tag 37 followed by a 16-byte byte string.
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a tag-37 UUID or the
    ///   byte string is not 16 bytes long.
    public mutating func readUUID() throws(WireDecodeError) -> UUID16 {
        let start = offset
        let tag = try readHead(major: 6)
        guard tag == 37 else {
            throw WireDecodeError(.cborUnsupportedTag, byteOffset: start)
        }
        let slice = try readByteString()
        guard slice.length == 16 else {
            throw WireDecodeError(.malformedUUID, byteOffset: start)
        }
        var raw: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { destination in
            slice.withBytes { source, length in
                for index in 0..<length {
                    destination[index] = source.load(fromByteOffset: index, as: UInt8.self)
                }
            }
        }
        return UUID16(bytes: raw)
    }

    // MARK: - Floating point

    /// Reads a CBOR floating-point value of any width.
    ///
    /// Half-precision, single-precision, and double-precision encodings are
    /// all accepted and widened to `Double`.
    ///
    /// - Throws: ``WireDecodeError`` when the item is not a floating-point
    ///   value.
    public mutating func readFloat() throws(WireDecodeError) -> Double {
        let (major, additional, start) = try readInitial()
        guard major == 7 else {
            throw WireDecodeError(.cborUnexpectedMajorType(expected: 7), byteOffset: start)
        }
        switch additional {
        case 25:
            let bits = try readBigEndian(2)
            return Self.halfToDouble(UInt16(truncatingIfNeeded: bits))
        case 26:
            let bits = try readBigEndian(4)
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 27:
            let bits = try readBigEndian(8)
            return Double(bitPattern: bits)
        default:
            throw WireDecodeError(.cborUnexpectedMajorType(expected: 7), byteOffset: start)
        }
    }

    // MARK: - Skipping

    /// Skips one complete CBOR item, validating its structure.
    ///
    /// Enforces the deterministic rules and the nesting bound, including for
    /// nested containers.
    ///
    /// - Throws: ``WireDecodeError`` when the item is malformed or exceeds the
    ///   nesting bound.
    public mutating func skipItem() throws(WireDecodeError) {
        let start = offset
        let (major, additional, _) = try readInitial()
        try skipItemBody(major: major, additional: additional, start: start, depth: 0)
    }

    private mutating func skipItemBody(
        major: UInt8, additional: UInt8, start: Int, depth: Int
    ) throws(WireDecodeError) {
        guard depth <= maximumDepth else {
            throw WireDecodeError(.cborNestingTooDeep, byteOffset: start)
        }
        switch major {
        case 0, 1:
            _ = try readArgument(major: major, additional: additional, start: start)
        case 2, 3:
            let length = try readArgument(major: major, additional: additional, start: start)
            guard length <= UInt64(remaining) else {
                throw WireDecodeError(.unexpectedEndOfInput, byteOffset: start)
            }
            let count = Int(length)
            if major == 3 {
                let slice = ByteSlice(pointer: bytes.advanced(by: offset), length: count)
                guard Self.isValidUTF8(slice) else {
                    throw WireDecodeError(.invalidUTF8, byteOffset: offset)
                }
            }
            offset += count
        case 4:
            let count = try readArgument(major: major, additional: additional, start: start)
            guard count <= UInt64(Int.max) else {
                throw WireDecodeError(.integerOverflow, byteOffset: start)
            }
            for _ in 0..<Int(count) {
                try skipItemNested(depth: depth + 1)
            }
        case 5:
            let count = try readArgument(major: major, additional: additional, start: start)
            guard count <= UInt64(Int.max) else {
                throw WireDecodeError(.integerOverflow, byteOffset: start)
            }
            try skipMapItems(Int(count), depth: depth + 1)
        case 6:
            let tag = try readArgument(major: major, additional: additional, start: start)
            guard tagPolicy.allows(tag) else {
                throw WireDecodeError(.cborUnsupportedTag, byteOffset: start)
            }
            try skipItemNested(depth: depth + 1)
        case 7:
            try skipSimpleOrFloat(additional: additional, start: start)
        default:
            throw WireDecodeError(.cborUnexpectedMajorType(expected: 0), byteOffset: start)
        }
    }

    private mutating func skipItemNested(depth: Int) throws(WireDecodeError) {
        let start = offset
        let (major, additional, _) = try readInitial()
        try skipItemBody(major: major, additional: additional, start: start, depth: depth)
    }

    private mutating func skipSimpleOrFloat(additional: UInt8, start: Int) throws(WireDecodeError) {
        switch additional {
        case 0...23:
            // Simple values 20, 21, and 22 are false, true, and null. Value 23
            // is `undefined`, which the profile does not carry.
            guard additional != 23 else {
                throw WireDecodeError(.cborUnsupportedSimpleValue, byteOffset: start)
            }
        case 24:
            let value = try readBigEndian(1)
            // Preferred serialization requires simple values 0-23 to use the
            // direct form rather than the one-byte extension.
            guard value >= 24 else {
                throw WireDecodeError(.cborNonMinimalInteger, byteOffset: start)
            }
        case 25:
            _ = try readBigEndian(2)
        case 26:
            _ = try readBigEndian(4)
        case 27:
            _ = try readBigEndian(8)
        case 31:
            throw WireDecodeError(.cborIndefiniteLength, byteOffset: start)
        default:
            throw WireDecodeError(.cborInvalidAdditionalInfo, byteOffset: start)
        }
    }

    // MARK: - Map duplicate detection

    private struct CBORKeyRecord {
        var major: UInt8 = 0
        var start: Int = 0
        var length: Int = 0
        var integerValue: UInt64 = 0

        func matches(_ other: CBORKeyRecord, bytes: UnsafePointer<UInt8>) -> Bool {
            guard major == other.major else { return false }
            switch major {
            case 0, 1:
                return integerValue == other.integerValue
            case 2, 3:
                guard length == other.length else { return false }
                for index in 0..<length where bytes[start + index] != bytes[other.start + index] {
                    return false
                }
                return true
            default:
                return false
            }
        }
    }

    private typealias CBORKeyStorage = InlineArray<24, CBORKeyRecord>

    private mutating func skipMapItems(_ count: Int, depth: Int) throws(WireDecodeError) {
        var keys = CBORKeyStorage(repeating: CBORKeyRecord())
        var keyCount = 0
        for _ in 0..<count {
            let record = try readMapKeyRecord(depth: depth)
            if record.major == 2 || record.major == 3 || record.major == 0 || record.major == 1 {
                for index in 0..<keyCount where keys[index].matches(record, bytes: bytes) {
                    throw WireDecodeError(.cborDuplicateMapKey, byteOffset: record.start)
                }
                if keyCount < CBORKeyStorage.count {
                    keys[keyCount] = record
                    keyCount += 1
                }
            }
            try skipItemNested(depth: depth)
        }
    }

    private mutating func readMapKeyRecord(depth: Int) throws(WireDecodeError) -> CBORKeyRecord {
        let start = offset
        let (major, additional, _) = try readInitial()
        switch major {
        case 0, 1:
            let value = try readArgument(major: major, additional: additional, start: start)
            return CBORKeyRecord(major: major, start: start, length: offset - start, integerValue: value)
        case 2, 3:
            let length = try readArgument(major: major, additional: additional, start: start)
            guard length <= UInt64(remaining) else {
                throw WireDecodeError(.unexpectedEndOfInput, byteOffset: start)
            }
            let count = Int(length)
            if major == 3 {
                let slice = ByteSlice(pointer: bytes.advanced(by: offset), length: count)
                guard Self.isValidUTF8(slice) else {
                    throw WireDecodeError(.invalidUTF8, byteOffset: offset)
                }
            }
            offset += count
            return CBORKeyRecord(major: major, start: start, length: offset - start, integerValue: 0)
        default:
            try skipItemBody(major: major, additional: additional, start: start, depth: depth)
            return CBORKeyRecord(major: 0xFF, start: start, length: offset - start, integerValue: 0)
        }
    }

    // MARK: - Helpers

    private static func isValidUTF8(_ slice: ByteSlice) -> Bool {
        slice.withBytes { pointer, length in
            let bytes = pointer.assumingMemoryBound(to: UInt8.self)
            var index = 0
            while index < length {
                let first = bytes[index]
                if first < 0x80 {
                    index += 1
                    continue
                }
                let continuationCount: Int
                var scalar: UInt32
                if first & 0xE0 == 0xC0 {
                    continuationCount = 1
                    scalar = UInt32(first & 0x1F)
                } else if first & 0xF0 == 0xE0 {
                    continuationCount = 2
                    scalar = UInt32(first & 0x0F)
                } else if first & 0xF8 == 0xF0 {
                    continuationCount = 3
                    scalar = UInt32(first & 0x07)
                } else {
                    return false
                }
                guard index + continuationCount < length else { return false }
                for offset in 1...continuationCount {
                    let next = bytes[index + offset]
                    guard next & 0xC0 == 0x80 else { return false }
                    scalar = (scalar << 6) | UInt32(next & 0x3F)
                }
                switch continuationCount {
                case 1 where scalar < 0x80: return false
                case 2 where scalar < 0x800: return false
                case 3 where scalar < 0x10000: return false
                default: break
                }
                if scalar > 0x10FFFF { return false }
                if scalar >= 0xD800 && scalar <= 0xDFFF { return false }
                index += continuationCount + 1
            }
            return true
        }
    }

    private static func halfToDouble(_ half: UInt16) -> Double {
        let sign = UInt64(half & 0x8000) << 48
        let exponent = UInt64((half >> 10) & 0x1F)
        let mantissa = UInt64(half & 0x3FF)
        if exponent == 0 {
            if mantissa == 0 {
                return Double(bitPattern: sign)
            }
            var shift = -1
            var significand = mantissa
            repeat {
                shift += 1
                significand <<= 1
            } while significand & 0x400 == 0
            let fraction = (significand & 0x3FF) << 42
            let biasedExponent = UInt64(1023 - 15 - shift) << 52
            return Double(bitPattern: sign | biasedExponent | fraction)
        }
        if exponent == 0x1F {
            if mantissa == 0 {
                return Double(bitPattern: sign | 0x7FF0_0000_0000_0000)
            }
            return Double.nan
        }
        let fraction = mantissa << 42
        let biasedExponent = (exponent - 15 + 1023) << 52
        return Double(bitPattern: sign | biasedExponent | fraction)
    }
}
