// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Encodes the example's JSON payload text as deterministic `axoloty/1` CBOR.
///
/// The `axoloty/1` profile carries CBOR on the wire (ADR 0009). An application
/// that starts from JSON text must encode it before it calls
/// `AxolotyRuntime.publish`. This example-local converter handles the JSON value
/// subset the example needs. It is not a runtime bridge: the runtime never
/// converts between `coaty/3` JSON and `axoloty/1` CBOR.
///
/// The scanner accepts objects, arrays, strings, booleans, null, and integers.
/// It builds string scalars one byte at a time, so non-ASCII text is Latin-1
/// rather than UTF-8, and it rejects fractional or exponent numbers.
enum JSONToCBOR {
    /// Returns the deterministic CBOR encoding of `json`.
    ///
    /// - Parameter json: A complete JSON value.
    /// - Returns: The CBOR bytes, or `nil` when `json` is not a complete value.
    static func encode(_ json: String) -> [UInt8]? {
        guard let value = ExampleJSONValue.parse(json) else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(json.utf8.count)
        value.appendCBOR(to: &output)
        return output
    }
}

/// A minimal JSON value used only to derive CBOR example payloads.
private indirect enum ExampleJSONValue {
    case null
    case bool(Bool)
    case number(Int)
    case string(String)
    case array([ExampleJSONValue])
    case object([(String, ExampleJSONValue)])

    static func parse(_ text: String) -> ExampleJSONValue? {
        var scanner = ExampleJSONScanner(Array(text.utf8))
        scanner.skipWhitespace()
        guard let value = scanner.parseValue() else { return nil }
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { return nil }
        return value
    }

    func appendCBOR(to output: inout [UInt8]) {
        switch self {
        case .null:
            output.append(0xF6)
        case .bool(let flag):
            output.append(flag ? 0xF5 : 0xF4)
        case .number(let value):
            if value >= 0 {
                Self.appendHead(major: 0, argument: UInt64(value), to: &output)
            } else {
                Self.appendHead(major: 1, argument: UInt64(-1 - value), to: &output)
            }
        case .string(let text):
            Self.appendString(text, to: &output)
        case .array(let items):
            Self.appendHead(major: 4, argument: UInt64(items.count), to: &output)
            for item in items { item.appendCBOR(to: &output) }
        case .object(let members):
            let sorted = members.sorted { lhs, rhs in
                let left = Array(lhs.0.utf8)
                let right = Array(rhs.0.utf8)
                if left.count != right.count { return left.count < right.count }
                return left.lexicographicallyPrecedes(right)
            }
            Self.appendHead(major: 5, argument: UInt64(sorted.count), to: &output)
            for (key, value) in sorted {
                Self.appendString(key, to: &output)
                value.appendCBOR(to: &output)
            }
        }
    }

    private static func appendString(_ text: String, to output: inout [UInt8]) {
        let bytes = Array(text.utf8)
        appendHead(major: 3, argument: UInt64(bytes.count), to: &output)
        output.append(contentsOf: bytes)
    }

    private static func appendHead(major: UInt8, argument: UInt64, to output: inout [UInt8]) {
        let base = major << 5
        switch argument {
        case 0..<24:
            output.append(base | UInt8(argument))
        case 24..<0x100:
            output.append(base | 24)
            output.append(UInt8(argument))
        case 0x100..<0x1_0000:
            output.append(base | 25)
            output.append(UInt8(argument >> 8))
            output.append(UInt8(argument & 0xFF))
        case 0x1_0000..<0x1_0000_0000:
            output.append(base | 26)
            for shift in stride(from: 24, through: 0, by: -8) {
                output.append(UInt8((argument >> UInt64(shift)) & 0xFF))
            }
        default:
            output.append(base | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                output.append(UInt8((argument >> UInt64(shift)) & 0xFF))
            }
        }
    }
}

/// A byte-oriented recursive-descent JSON reader.
private struct ExampleJSONScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        while index < bytes.count, whitespace.contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() -> ExampleJSONValue? {
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x22: return parseString().map(ExampleJSONValue.string)
        case 0x74: return consume("true") ? .bool(true) : nil
        case 0x66: return consume("false") ? .bool(false) : nil
        case 0x6E: return consume("null") ? .null : nil
        case 0x2D, 0x30...0x39: return parseNumber().map(ExampleJSONValue.number)
        default: return nil
        }
    }

    private mutating func parseObject() -> ExampleJSONValue? {
        index += 1
        var members: [(String, ExampleJSONValue)] = []
        skipWhitespace()
        if peek(0x7D) { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard consumeByte(0x3A) else { return nil }
            guard let value = parseValue() else { return nil }
            members.append((key, value))
            skipWhitespace()
            if consumeByte(0x2C) { continue }
            guard consumeByte(0x7D) else { return nil }
            return .object(members)
        }
    }

    private mutating func parseArray() -> ExampleJSONValue? {
        index += 1
        var items: [ExampleJSONValue] = []
        skipWhitespace()
        if peek(0x5D) { index += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            if consumeByte(0x2C) { continue }
            guard consumeByte(0x5D) else { return nil }
            return .array(items)
        }
    }

    private mutating func parseString() -> String? {
        guard consumeByte(0x22) else { return nil }
        var scalars: [Character] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x22:
                return String(scalars)
            case 0x5C:
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22: scalars.append("\"")
                case 0x5C: scalars.append("\\")
                case 0x2F: scalars.append("/")
                case 0x62: scalars.append("\u{08}")
                case 0x66: scalars.append("\u{0C}")
                case 0x6E: scalars.append("\n")
                case 0x72: scalars.append("\r")
                case 0x74: scalars.append("\t")
                case 0x75: guard let scalar = parseUnicodeEscape() else { return nil }
                    scalars.append(scalar)
                default: return nil
                }
            default:
                guard byte >= 0x20 else { return nil }
                scalars.append(Character(UnicodeScalar(byte)))
            }
        }
        return nil
    }

    private mutating func parseUnicodeEscape() -> Character? {
        guard let value = parseHexQuad() else { return nil }
        if (0xD800...0xDBFF).contains(value) {
            guard consumeByte(0x5C), consumeByte(0x75), let trail = parseHexQuad(),
                  (0xDC00...0xDFFF).contains(trail) else { return nil }
            let combined = 0x10000 + ((value - 0xD800) << 10) + (trail - 0xDC00)
            return UnicodeScalar(combined).map(Character.init)
        }
        guard !(0xDC00...0xDFFF).contains(value) else { return nil }
        return UnicodeScalar(value).map(Character.init)
    }

    private mutating func parseHexQuad() -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count, let digit = Self.hexDigit(bytes[index]) else { return nil }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() -> Int? {
        let start = index
        if peek(0x2D) { index += 1 }
        var digits = 0
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            index += 1
            digits += 1
        }
        guard digits > 0 else { index = start; return nil }
        guard let value = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            index = start
            return nil
        }
        return value
    }

    private mutating func consume(_ literal: String) -> Bool {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count else { return false }
        for offset in literalBytes.indices where bytes[index + offset] != literalBytes[offset] { return false }
        index += literalBytes.count
        return true
    }

    private mutating func consumeByte(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func peek(_ byte: UInt8) -> Bool {
        index < bytes.count && bytes[index] == byte
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }
}
