// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A deterministic CBOR encoder.
///
/// The encoder emits RFC 8949 §4.2.1 core deterministic encoding: definite
/// lengths only, shortest-form heads, preferred simple-value form, the
/// shortest of single or double precision for floats, and map keys sorted by
/// their encoded bytes. Half-precision is read but never emitted. It is the
/// write half of the inspector's "read and write CBOR captures" capability.
public enum CBOREncoder {
    /// Encodes a value as deterministic CBOR.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The deterministic CBOR bytes.
    public static func encode(_ value: CBORValue) -> [UInt8] {
        var output: [UInt8] = []
        append(value, to: &output)
        return output
    }

    private static func append(_ value: CBORValue, to output: inout [UInt8]) {
        switch value {
        case .unsigned(let number):
            writeHead(major: 0, argument: number, to: &output)
        case .negative(let argument):
            writeHead(major: 1, argument: argument, to: &output)
        case .byteString(let bytes):
            writeHead(major: 2, argument: UInt64(bytes.count), to: &output)
            output.append(contentsOf: bytes)
        case .textString(let text):
            appendText(text, to: &output)
        case .chunkedByteString(let chunks):
            let bytes = chunks.flatMap { $0 }
            writeHead(major: 2, argument: UInt64(bytes.count), to: &output)
            output.append(contentsOf: bytes)
        case .chunkedTextString(let chunks):
            appendText(chunks.joined(), to: &output)
        case .array(let items, _):
            writeHead(major: 4, argument: UInt64(items.count), to: &output)
            for item in items { append(item, to: &output) }
        case .map(let entries, _):
            appendMap(entries, to: &output)
        case .tag(let tag, let inner):
            writeHead(major: 6, argument: tag, to: &output)
            append(inner, to: &output)
        case .simple(let simple):
            if simple < 24 {
                output.append(0xE0 | simple)
            } else {
                output.append(0xF8)
                output.append(simple)
            }
        case .boolean(let flag):
            output.append(flag ? 0xF5 : 0xF4)
        case .null:
            output.append(0xF6)
        case .undefined:
            output.append(0xF7)
        case .float(let number):
            appendFloat(number, to: &output)
        }
    }

    private static func appendText(_ text: String, to output: inout [UInt8]) {
        let bytes = Array(text.utf8)
        writeHead(major: 3, argument: UInt64(bytes.count), to: &output)
        output.append(contentsOf: bytes)
    }

    private static func appendMap(_ entries: [CBORMapEntry], to output: inout [UInt8]) {
        var encoded: [(key: [UInt8], value: CBORValue)] = []
        encoded.reserveCapacity(entries.count)
        for entry in entries {
            var keyBytes: [UInt8] = []
            append(entry.key, to: &keyBytes)
            encoded.append((key: keyBytes, value: entry.value))
        }
        encoded.sort { isOrderedBefore($0.key, $1.key) }
        writeHead(major: 5, argument: UInt64(encoded.count), to: &output)
        for entry in encoded {
            output.append(contentsOf: entry.key)
            append(entry.value, to: &output)
        }
    }

    /// Orders map keys by their deterministic encoded bytes.
    private static func isOrderedBefore(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        let shared = min(lhs.count, rhs.count)
        for index in 0..<shared where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index]
        }
        return lhs.count < rhs.count
    }

    private static func appendFloat(_ number: Double, to output: inout [UInt8]) {
        if number.isNaN {
            // Canonical NaN: half-precision quiet NaN.
            output.append(contentsOf: [0xF9, 0x7E, 0x00])
        } else if let single = singlePrecisionBits(number) {
            output.append(0xFA)
            output.append(UInt8((single >> 24) & 0xFF))
            output.append(UInt8((single >> 16) & 0xFF))
            output.append(UInt8((single >> 8) & 0xFF))
            output.append(UInt8(single & 0xFF))
        } else {
            let bits = number.bitPattern
            output.append(0xFB)
            var shift = 56
            while shift >= 0 {
                output.append(UInt8((bits >> UInt64(shift)) & 0xFF))
                shift -= 8
            }
        }
    }

    /// Returns the single-precision bit pattern when `number` is exactly
    /// representable as a `Float`, including both infinities, or `nil` when it
    /// needs double precision.
    ///
    /// - Parameter number: The value to test.
    /// - Returns: The single-precision bit pattern, or `nil`.
    private static func singlePrecisionBits(_ number: Double) -> UInt32? {
        if number.isFinite {
            return Float(exactly: number)?.bitPattern
        }
        // ±Infinity is exactly representable in single precision; NaN is
        // handled by the caller before reaching this point.
        return number.isInfinite ? Float(number).bitPattern : nil
    }

    private static func writeHead(major: UInt8, argument: UInt64, to output: inout [UInt8]) {
        let tag = major << 5
        if argument < 24 {
            output.append(tag | UInt8(argument))
        } else if argument <= 0xFF {
            output.append(tag | 24)
            output.append(UInt8(argument))
        } else if argument <= 0xFFFF {
            output.append(tag | 25)
            output.append(UInt8((argument >> 8) & 0xFF))
            output.append(UInt8(argument & 0xFF))
        } else if argument <= 0xFFFF_FFFF {
            output.append(tag | 26)
            output.append(UInt8((argument >> 24) & 0xFF))
            output.append(UInt8((argument >> 16) & 0xFF))
            output.append(UInt8((argument >> 8) & 0xFF))
            output.append(UInt8(argument & 0xFF))
        } else {
            output.append(tag | 27)
            var shift = 56
            while shift >= 0 {
                output.append(UInt8((argument >> UInt64(shift)) & 0xFF))
                shift -= 8
            }
        }
    }
}
