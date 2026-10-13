// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol
import AxolotyWire

/// Re-encodes an internally generated host payload for the bound wire profile.
///
/// The host runtime's object model and lifecycle payload builders produce
/// `coaty/3` JSON. ADR 0009 binds Zenoh to `axoloty/1` CBOR, so a host runtime
/// composed with a CBOR transport must publish CBOR bytes for the envelopes it
/// generates itself. `coaty/3` JSON is returned unchanged, so the sealed MQTT
/// byte contract never changes.
///
/// This is not a public or general JSON/CBOR bridge. It converts only the
/// bounded payloads the runtime builds from its own object metadata and
/// lifecycle values, and the result must fit ``WireBufferConfig/maxPayloadSize``.
enum RuntimeWirePayload {
    /// Returns `json` unchanged for `coaty/3`, or its deterministic CBOR form
    /// for `axoloty/1`.
    ///
    /// - Parameters:
    ///   - json: A complete JSON value produced by an internal encoder.
    ///   - profile: The profile the transport binding carries.
    /// - Returns: The bytes to publish for `profile`.
    /// - Throws: ``ProtocolError`` with ``ProtocolError/Code/capacityExceeded``
    ///   when the CBOR form does not fit the bounded payload buffer, or with
    ///   ``ProtocolError/Code/malformedPayload`` when `json` is not one
    ///   complete JSON value.
    static func encode(json: [UInt8], profile: WireProfile) throws(ProtocolError) -> [UInt8] {
        switch profile {
        case .coaty3JSON:
            return json
        case .axoloty1CBOR:
            return try RuntimeJSONCBOR.encode(json)
        }
    }
}

/// Converts one bounded JSON value into deterministic CBOR.
///
/// The encoder parses the JSON text directly and writes CBOR through
/// ``CBORWriter``. Map keys use the RFC 8949 §4.2.1 canonical order. Integers
/// keep their exact value when they fit a CBOR integer; every other number uses
/// the shortest lossless float form.
enum RuntimeJSONCBOR {
    /// Encodes one complete JSON value as CBOR.
    ///
    /// - Parameter json: The JSON text bytes.
    /// - Returns: The canonical CBOR encoding.
    /// - Throws: ``ProtocolError`` for malformed input or capacity exhaustion.
    static func encode(_ json: [UInt8]) throws(ProtocolError) -> [UInt8] {
        guard let value = RuntimeJSONValue.parse(json) else {
            throw ProtocolError(.malformedPayload)
        }
        var output = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
        var length = 0
        var failed = false
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                failed = true
                return
            }
            var writer = CBORWriter(buffer: base, capacity: buffer.count)
            do {
                try value.write(to: &writer)
                length = writer.position
            } catch {
                failed = true
            }
        }
        guard !failed else { throw ProtocolError(.capacityExceeded) }
        output.removeSubrange(length..<output.count)
        return output
    }

    /// Returns the encoded CBOR text-string bytes for one map key.
    static func encodedText(_ text: String) -> [UInt8] {
        let content = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(content.count + 5)
        appendTextHead(content.count, to: &result)
        result.append(contentsOf: content)
        return result
    }

    private static func appendTextHead(_ length: Int, to output: inout [UInt8]) {
        if length < 24 {
            output.append(0x60 | UInt8(length))
        } else if length <= 0xFF {
            output.append(0x78)
            output.append(UInt8(length))
        } else if length <= 0xFFFF {
            output.append(0x79)
            output.append(UInt8(length >> 8))
            output.append(UInt8(length & 0xFF))
        } else {
            output.append(0x7A)
            output.append(UInt8((length >> 24) & 0xFF))
            output.append(UInt8((length >> 16) & 0xFF))
            output.append(UInt8((length >> 8) & 0xFF))
            output.append(UInt8(length & 0xFF))
        }
    }
}

/// One parsed JSON value used only to derive CBOR.
enum RuntimeJSONValue {
    case null
    case bool(Bool)
    case number([UInt8])
    case string([UInt8])
    case array([RuntimeJSONValue])
    case object([(String, RuntimeJSONValue)])

    /// Parses one complete JSON value.
    ///
    /// - Parameter bytes: The JSON text bytes.
    /// - Returns: The parsed value, or `nil` when `bytes` is not one complete
    ///   JSON value.
    static func parse(_ bytes: [UInt8]) -> RuntimeJSONValue? {
        var scanner = RuntimeJSONScanner(bytes: bytes)
        scanner.skipWhitespace()
        guard let value = scanner.parseValue() else { return nil }
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { return nil }
        return value
    }

    /// Writes this value through a CBOR writer.
    func write(to writer: inout CBORWriter) throws {
        switch self {
        case .null:
            try writer.writeNull()
        case .bool(let flag):
            try writer.writeBool(flag)
        case .number(let lexeme):
            try Self.writeNumber(lexeme, to: &writer)
        case .string(let content):
            try Self.writeText(content, to: &writer)
        case .array(let items):
            try writer.writeArrayHeader(items.count)
            for item in items { try item.write(to: &writer) }
        case .object(let members):
            let ordered = members.sorted { lhs, rhs in
                RuntimeJSONCBOR.encodedText(lhs.0).lexicographicallyPrecedes(
                    RuntimeJSONCBOR.encodedText(rhs.0)
                )
            }
            try writer.writeMapHeader(ordered.count)
            for (key, value) in ordered {
                try Self.writeText(Array(key.utf8), to: &writer)
                try value.write(to: &writer)
            }
        }
    }

    private static func writeText(_ content: [UInt8], to writer: inout CBORWriter) throws {
        var failure: WireEncodeError?
        content.withUnsafeBufferPointer { buffer in
            do {
                if let base = buffer.baseAddress {
                    try writer.writeTextString(ByteSlice(bytes: base, length: buffer.count))
                } else {
                    try writer.writeTextString(ByteSlice.empty)
                }
            } catch let thrown as WireEncodeError {
                failure = thrown
            } catch {
                failure = .invalidValue
            }
        }
        if let failure { throw failure }
    }

    private static func writeNumber(_ lexeme: [UInt8], to writer: inout CBORWriter) throws {
        let text = String(decoding: lexeme, as: UTF8.self)
        let isIntegral = !lexeme.contains(0x2E) && !lexeme.contains(0x65) && !lexeme.contains(0x45)
        if isIntegral, let value = Int64(text) {
            try writer.writeInteger(value)
            return
        }
        if isIntegral, let value = UInt64(text) {
            try writer.writeUnsigned(value)
            return
        }
        guard let value = Double(text) else { throw WireEncodeError.invalidValue }
        try writer.writeFloat64(value)
    }
}

/// A byte-oriented recursive-descent JSON reader.
struct RuntimeJSONScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        while index < bytes.count, whitespace.contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() -> RuntimeJSONValue? {
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x22: return parseString().map(RuntimeJSONValue.string)
        case 0x74: return consume("true") ? .bool(true) : nil
        case 0x66: return consume("false") ? .bool(false) : nil
        case 0x6E: return consume("null") ? .null : nil
        case 0x2D, 0x30...0x39: return parseNumber().map(RuntimeJSONValue.number)
        default: return nil
        }
    }

    private mutating func parseObject() -> RuntimeJSONValue? {
        index += 1
        var members: [(String, RuntimeJSONValue)] = []
        skipWhitespace()
        if peek(0x7D) { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard consumeByte(0x3A), let value = parseValue() else { return nil }
            members.append((String(decoding: key, as: UTF8.self), value))
            skipWhitespace()
            if consumeByte(0x2C) { continue }
            guard consumeByte(0x7D) else { return nil }
            return .object(members)
        }
    }

    private mutating func parseArray() -> RuntimeJSONValue? {
        index += 1
        var items: [RuntimeJSONValue] = []
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

    private mutating func parseString() -> [UInt8]? {
        guard consumeByte(0x22) else { return nil }
        var scalars: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x22:
                return scalars
            case 0x5C:
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22: scalars.append(0x22)
                case 0x5C: scalars.append(0x5C)
                case 0x2F: scalars.append(0x2F)
                case 0x62: scalars.append(0x08)
                case 0x66: scalars.append(0x0C)
                case 0x6E: scalars.append(0x0A)
                case 0x72: scalars.append(0x0D)
                case 0x74: scalars.append(0x09)
                case 0x75:
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    scalars.append(contentsOf: Array(String(scalar).utf8))
                default:
                    return nil
                }
            default:
                guard byte >= 0x20 else { return nil }
                scalars.append(byte)
            }
        }
        return nil
    }

    private mutating func parseUnicodeEscape() -> UnicodeScalar? {
        guard let value = parseHexQuad() else { return nil }
        if (0xD800...0xDBFF).contains(value) {
            guard consumeByte(0x5C), consumeByte(0x75), let trail = parseHexQuad(),
                  (0xDC00...0xDFFF).contains(trail) else { return nil }
            let combined = 0x10000 + ((value - 0xD800) << 10) + (trail - 0xDC00)
            return UnicodeScalar(combined)
        }
        guard !(0xDC00...0xDFFF).contains(value) else { return nil }
        return UnicodeScalar(value)
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

    private mutating func parseNumber() -> [UInt8]? {
        let start = index
        if peek(0x2D) { index += 1 }
        var digits = 0
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            index += 1
            digits += 1
        }
        guard digits > 0 else { index = start; return nil }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            var fraction = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
                fraction += 1
            }
            guard fraction > 0 else { index = start; return nil }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            var exponent = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
                exponent += 1
            }
            guard exponent > 0 else { index = start; return nil }
        }
        return Array(bytes[start..<index])
    }

    private mutating func consume(_ literal: String) -> Bool {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count else { return false }
        for offset in literalBytes.indices where bytes[index + offset] != literalBytes[offset] {
            return false
        }
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
