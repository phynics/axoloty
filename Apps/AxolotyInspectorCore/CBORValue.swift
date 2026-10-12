// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One key/value pair of a CBOR map.
///
/// A map keeps its entries in wire order so diagnostic rendering and the
/// deterministic encoder both observe the same sequence.
public struct CBORMapEntry: Equatable, Sendable {
    /// The map key.
    public let key: CBORValue
    /// The value bound to ``key``.
    public let value: CBORValue

    /// Creates a map entry.
    ///
    /// - Parameters:
    ///   - key: The map key.
    ///   - value: The value bound to `key`.
    public init(key: CBORValue, value: CBORValue) {
        self.key = key
        self.value = value
    }
}

/// A bounded representation of an RFC 8949 CBOR data item.
///
/// The model is intentionally lossless enough to round-trip a wire payload
/// through diagnostic notation: it keeps indefinite-length markers and the raw
/// negative argument. It carries no protocol meaning, so a tool can render a
/// payload the runtime would not yet accept.
///
/// Negative integers store the major-type-1 argument `n`, not the signed
/// value. The mathematical value is `-1 - n`, which covers the full CBOR range
/// from `-1` through `-2^64` without overflowing a signed integer.
public indirect enum CBORValue: Equatable, Sendable {
    /// A major type 0 unsigned integer.
    case unsigned(UInt64)
    /// A major type 1 negative integer carrying argument `n`; value `-1 - n`.
    case negative(UInt64)
    /// A definite-length byte string.
    case byteString([UInt8])
    /// A definite-length UTF-8 text string.
    case textString(String)
    /// An indefinite-length byte string preserved as its chunks.
    case chunkedByteString([[UInt8]])
    /// An indefinite-length text string preserved as its chunks.
    case chunkedTextString([String])
    /// An array. `indefinite` records whether the wire form used an
    /// indefinite-length break.
    case array([CBORValue], indefinite: Bool)
    /// A map. `indefinite` records whether the wire form used an
    /// indefinite-length break.
    case map([CBORMapEntry], indefinite: Bool)
    /// A semantic tag wrapping `value`.
    case tag(UInt64, CBORValue)
    /// A simple value that is not `false`, `true`, `null`, or `undefined`.
    case simple(UInt8)
    /// A boolean (simple values 20 and 21).
    case boolean(Bool)
    /// The CBOR `null` value (simple value 22).
    case null
    /// The CBOR `undefined` value (simple value 23).
    case undefined
    /// A floating-point value.
    case float(Double)
}

extension CBORValue {
    /// The concatenated bytes of a byte-string value, definite or chunked.
    public var bytesValue: [UInt8]? {
        switch self {
        case .byteString(let bytes): return bytes
        case .chunkedByteString(let chunks): return chunks.flatMap { $0 }
        default: return nil
        }
    }

    /// The concatenated text of a text-string value, definite or chunked.
    public var textValue: String? {
        switch self {
        case .textString(let text): return text
        case .chunkedTextString(let chunks): return chunks.joined()
        default: return nil
        }
    }
}
