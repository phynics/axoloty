// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A bounded CBOR decode failure.
///
/// The inspector decoder is deliberately more permissive than the
/// `axoloty/1` wire reader: an operator needs to render a malformed or
/// non-minimal payload to diagnose the producer. Hard bounds still apply so a
/// hostile capture cannot exhaust memory.
public enum CBORDecodingError: Error, Equatable, Sendable {
    /// The buffer ended before the data item was complete.
    case truncated
    /// The input ended with unconsumed bytes.
    case trailingBytes
    /// A reserved or invalid additional-information value was read.
    case invalidAdditionalInformation(UInt8)
    /// A break byte (0xFF) appeared outside an indefinite-length item.
    case unexpectedBreak
    /// A text string was not valid UTF-8.
    case invalidUTF8
    /// The nesting depth exceeded the configured bound.
    case depthExceeded
    /// The total item count exceeded the configured bound.
    case itemCountExceeded
    /// The input length exceeded the configured bound.
    case byteCountExceeded
    /// A container declared more elements than the configured bound.
    case containerLengthExceeded
}

/// Limits applied by ``CBORDecoder``.
public struct CBORDecodeLimits: Equatable, Sendable {
    /// Maximum accepted input length in bytes.
    public var maximumBytes: Int
    /// Maximum accepted container nesting depth.
    public var maximumDepth: Int
    /// Maximum accepted number of decoded data items.
    public var maximumItems: Int
    /// Maximum accepted declared array or map length.
    public var maximumContainerLength: Int

    /// Creates decode limits.
    ///
    /// - Parameters:
    ///   - maximumBytes: Maximum accepted input length in bytes.
    ///   - maximumDepth: Maximum accepted container nesting depth.
    ///   - maximumItems: Maximum accepted number of decoded data items.
    ///   - maximumContainerLength: Maximum accepted declared container length.
    public init(
        maximumBytes: Int,
        maximumDepth: Int,
        maximumItems: Int,
        maximumContainerLength: Int
    ) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
        self.maximumItems = maximumItems
        self.maximumContainerLength = maximumContainerLength
    }

    /// Limits aligned with the `axoloty/1` profile bounds, widened enough to
    /// also inspect a slightly oversized or non-deterministic capture.
    public static let profile = CBORDecodeLimits(
        maximumBytes: 1 << 20,
        maximumDepth: 32,
        maximumItems: 65_536,
        maximumContainerLength: 65_536
    )
}

/// A bounded, lenient CBOR decoder.
///
/// The decoder accepts definite and indefinite lengths, non-minimal heads,
/// and every numeric width. It never recursively allocates without bound.
public struct CBORDecoder {
    private let bytes: [UInt8]
    private let limits: CBORDecodeLimits
    private var index: Int
    private var itemCount: Int

    /// Creates a decoder over a byte buffer.
    ///
    /// - Parameters:
    ///   - bytes: The CBOR bytes to decode.
    ///   - limits: The bounds applied while decoding.
    public init(_ bytes: [UInt8], limits: CBORDecodeLimits = .profile) {
        self.bytes = bytes
        self.limits = limits
        self.index = 0
        self.itemCount = 0
    }

    /// Whether every byte has been consumed.
    public var isAtEnd: Bool { index >= bytes.count }

    /// Decodes exactly one data item and rejects trailing bytes.
    ///
    /// - Returns: The decoded value.
    /// - Throws: ``CBORDecodingError`` when the input is malformed.
    public mutating func decode() throws(CBORDecodingError) -> CBORValue {
        guard bytes.count <= limits.maximumBytes else { throw .byteCountExceeded }
        let value = try decodeItem(depth: 0)
        guard isAtEnd else { throw .trailingBytes }
        return value
    }

    private mutating func readByte() throws(CBORDecodingError) -> UInt8 {
        guard index < bytes.count else { throw .truncated }
        let byte = bytes[index]
        index += 1
        return byte
    }

    private mutating func readUnsigned(_ count: Int) throws(CBORDecodingError) -> UInt64 {
        guard count >= 0, count <= 8, index + count <= bytes.count else { throw .truncated }
        var value: UInt64 = 0
        for offset in 0..<count {
            value = (value << 8) | UInt64(bytes[index + offset])
        }
        index += count
        return value
    }

    private mutating func readArgument(_ additional: UInt8) throws(CBORDecodingError) -> UInt64 {
        switch additional {
        case 0..<24: return UInt64(additional)
        case 24: return UInt64(try readByte())
        case 25: return try readUnsigned(2)
        case 26: return try readUnsigned(4)
        case 27: return try readUnsigned(8)
        default: throw .invalidAdditionalInformation(additional)
        }
    }

    private mutating func peekIsBreak() -> Bool {
        index < bytes.count && bytes[index] == 0xFF
    }

    private mutating func decodeItem(depth: Int) throws(CBORDecodingError) -> CBORValue {
        guard depth <= limits.maximumDepth else { throw .depthExceeded }
        itemCount += 1
        guard itemCount <= limits.maximumItems else { throw .itemCountExceeded }
        let initial = try readByte()
        let major = initial >> 5
        let additional = initial & 0x1F

        switch major {
        case 0:
            return .unsigned(try readArgument(additional))
        case 1:
            return .negative(try readArgument(additional))
        case 2:
            switch try readStringBody(additional, major: 2) {
            case .definite(let bytes): return .byteString(bytes)
            case .chunked(let chunks): return .chunkedByteString(chunks)
            }
        case 3:
            switch try readStringBody(additional, major: 3) {
            case .definite(let bytes):
                guard let text = String(bytes: bytes, encoding: .utf8) else { throw .invalidUTF8 }
                return .textString(text)
            case .chunked(let chunks):
                var texts: [String] = []
                texts.reserveCapacity(chunks.count)
                for chunk in chunks {
                    guard let text = String(bytes: chunk, encoding: .utf8) else { throw .invalidUTF8 }
                    texts.append(text)
                }
                return .chunkedTextString(texts)
            }
        case 4:
            return try decodeArray(additional, depth: depth)
        case 5:
            return try decodeMap(additional, depth: depth)
        case 6:
            let tag = try readArgument(additional)
            return .tag(tag, try decodeItem(depth: depth + 1))
        default:
            return try decodeSimpleOrFloat(additional)
        }
    }

    private mutating func decodeArray(_ additional: UInt8, depth: Int) throws(CBORDecodingError) -> CBORValue {
        if additional == 31 {
            var items: [CBORValue] = []
            while true {
                if peekIsBreak() {
                    index += 1
                    break
                }
                guard !isAtEnd else { throw .truncated }
                items.append(try decodeItem(depth: depth + 1))
            }
            return .array(items, indefinite: true)
        }
        let count = try readArgument(additional)
        guard count <= UInt64(limits.maximumContainerLength) else { throw .containerLengthExceeded }
        var items: [CBORValue] = []
        items.reserveCapacity(Int(count))
        for _ in 0..<count {
            items.append(try decodeItem(depth: depth + 1))
        }
        return .array(items, indefinite: false)
    }

    private mutating func decodeMap(_ additional: UInt8, depth: Int) throws(CBORDecodingError) -> CBORValue {
        if additional == 31 {
            var entries: [CBORMapEntry] = []
            while true {
                if peekIsBreak() {
                    index += 1
                    break
                }
                guard !isAtEnd else { throw .truncated }
                let key = try decodeItem(depth: depth + 1)
                guard !peekIsBreak(), !isAtEnd else { throw .truncated }
                let value = try decodeItem(depth: depth + 1)
                entries.append(CBORMapEntry(key: key, value: value))
            }
            return .map(entries, indefinite: true)
        }
        let count = try readArgument(additional)
        guard count <= UInt64(limits.maximumContainerLength) else { throw .containerLengthExceeded }
        var entries: [CBORMapEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            let key = try decodeItem(depth: depth + 1)
            let value = try decodeItem(depth: depth + 1)
            entries.append(CBORMapEntry(key: key, value: value))
        }
        return .map(entries, indefinite: false)
    }

    /// The body of a byte or text string.
    private enum StringBody {
        case definite([UInt8])
        case chunked([[UInt8]])
    }

    /// Reads the body of a byte or text string, definite or indefinite.
    ///
    /// - Parameters:
    ///   - additional: The additional information of the string head.
    ///   - major: The string's major type, either 2 (bytes) or 3 (text).
    /// - Returns: The string body.
    /// - Throws: ``CBORDecodingError`` when the body is malformed or exceeds
    ///   the configured limits.
    private mutating func readStringBody(
        _ additional: UInt8,
        major: UInt8
    ) throws(CBORDecodingError) -> StringBody {
        if additional == 31 {
            var chunks: [[UInt8]] = []
            while true {
                if peekIsBreak() {
                    index += 1
                    break
                }
                let chunkHead = try readByte()
                let chunkMajor = chunkHead >> 5
                let chunkAdditional = chunkHead & 0x1F
                guard chunkMajor == major, chunkAdditional != 31 else {
                    throw .invalidAdditionalInformation(chunkAdditional)
                }
                let length = try readArgument(chunkAdditional)
                guard length <= UInt64(limits.maximumContainerLength) else { throw .containerLengthExceeded }
                chunks.append(try readRaw(count: Int(length)))
            }
            return .chunked(chunks)
        }
        let length = try readArgument(additional)
        guard length <= UInt64(limits.maximumContainerLength) else { throw .containerLengthExceeded }
        return .definite(try readRaw(count: Int(length)))
    }

    private mutating func readRaw(count: Int) throws(CBORDecodingError) -> [UInt8] {
        guard count >= 0, index + count <= bytes.count else { throw .truncated }
        let slice = Array(bytes[index..<(index + count)])
        index += count
        return slice
    }

    private mutating func decodeSimpleOrFloat(_ additional: UInt8) throws(CBORDecodingError) -> CBORValue {
        switch additional {
        case 20: return .boolean(false)
        case 21: return .boolean(true)
        case 22: return .null
        case 23: return .undefined
        case 24: return .simple(try readByte())
        case 25:
            let bits = UInt16(truncatingIfNeeded: try readUnsigned(2))
            return .float(Self.decodeHalf(bits))
        case 26:
            let bits = UInt32(truncatingIfNeeded: try readUnsigned(4))
            return .float(Double(Float(bitPattern: bits)))
        case 27:
            let bits = try readUnsigned(8)
            return .float(Double(bitPattern: bits))
        case 28..<31:
            throw .invalidAdditionalInformation(additional)
        case 31:
            throw .unexpectedBreak
        default:
            // Additional information 0..19 are unassigned simple values.
            return .simple(additional)
        }
    }

    /// Decodes an IEEE 754 binary16 value into a `Double`.
    private static func decodeHalf(_ bits: UInt16) -> Double {
        let sign = Double((bits >> 15) & 1)
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = Int(bits & 0x3FF)
        if exponent == 0 {
            return (sign == 0 ? 1 : -1) * Double(fraction) * pow(2.0, -24)
        }
        if exponent == 0x1F {
            return fraction == 0 ? (sign == 0 ? .infinity : -.infinity) : .nan
        }
        return (sign == 0 ? 1 : -1) * (1 + Double(fraction) / 1024) * pow(2.0, Double(exponent - 15))
    }
}
