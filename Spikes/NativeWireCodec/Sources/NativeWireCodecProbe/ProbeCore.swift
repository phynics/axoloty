// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

enum NativeJSONError: Error {
    case invalidSyntax
    case invalidString
    case invalidNumber
    case nestingLimit
    case duplicateField
    case missingField
    case typeMismatch
    case integerOverflow
}

struct StrictAssociate {
    let ioSourceId: UUID16
    let ioActorId: UUID16
    let associatingRoute: ByteSlice?
    let isExternalRoute: Bool?
    let updateRate: Int?
}

struct StrictIoValue {
    let payload: ByteSlice
}

struct NativeStrictReader {
    private let bytes: UnsafeRawPointer
    private let length: Int
    private var position: Int = 0
    private static let maximumDepth = 32

    init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.bytes = UnsafeRawPointer(bytes)
        self.length = length
    }

    mutating func decodeAssociate() throws(NativeJSONError) -> StrictAssociate {
        try beginObject()
        var source: UUID16?
        var actor: UUID16?
        var route: ByteSlice?
        var external: Bool?
        var rate: Int?
        var seen: UInt8 = 0

        if try consumeObjectEnd() {
            throw .missingField
        }
        while true {
            let key = try parseString()
            try expect(0x3A)
            if key.equals("ioSourceId") {
                try markSeen(&seen, bit: 1)
                source = try parseUUID()
            } else if key.equals("ioActorId") {
                try markSeen(&seen, bit: 2)
                actor = try parseUUID()
            } else if key.equals("associatingRoute") {
                try markSeen(&seen, bit: 4)
                if try consumeNull() { route = nil } else { route = try parseString() }
            } else if key.equals("isExternalRoute") {
                try markSeen(&seen, bit: 8)
                if try consumeNull() { external = nil } else { external = try parseBool() }
            } else if key.equals("updateRate") {
                try markSeen(&seen, bit: 16)
                if try consumeNull() { rate = nil } else { rate = try parseInt() }
            } else {
                try skipValue(depth: 1)
            }
            if try consumeObjectEnd() { break }
            try expect(0x2C)
        }
        try finishDocument()
        guard let source, let actor else { throw .missingField }
        return StrictAssociate(
            ioSourceId: source,
            ioActorId: actor,
            associatingRoute: route,
            isExternalRoute: external,
            updateRate: rate
        )
    }

    mutating func decodeIoValue() throws(NativeJSONError) -> StrictIoValue {
        try beginObject()
        var payload: ByteSlice?
        var seen = false
        if try consumeObjectEnd() { throw .missingField }
        while true {
            let key = try parseString()
            try expect(0x3A)
            if key.equals("payload") {
                guard !seen else { throw .duplicateField }
                seen = true
                skipWhitespace()
                let start = position
                try skipValue(depth: 1)
                payload = slice(start, position)
            } else {
                try skipValue(depth: 1)
            }
            if try consumeObjectEnd() { break }
            try expect(0x2C)
        }
        try finishDocument()
        guard let payload else { throw .missingField }
        return StrictIoValue(payload: payload)
    }

    private mutating func markSeen(_ seen: inout UInt8, bit: UInt8) throws(NativeJSONError) {
        guard seen & bit == 0 else { throw .duplicateField }
        seen |= bit
    }

    private mutating func beginObject() throws(NativeJSONError) {
        skipWhitespace()
        try expectRaw(0x7B)
    }

    private mutating func consumeObjectEnd() throws(NativeJSONError) -> Bool {
        skipWhitespace()
        guard position < length else { throw .invalidSyntax }
        if byte() == 0x7D {
            position += 1
            return true
        }
        return false
    }

    private mutating func finishDocument() throws(NativeJSONError) {
        skipWhitespace()
        guard position == length else { throw .invalidSyntax }
    }

    private mutating func expect(_ expected: UInt8) throws(NativeJSONError) {
        skipWhitespace()
        try expectRaw(expected)
    }

    private mutating func expectRaw(_ expected: UInt8) throws(NativeJSONError) {
        guard position < length, byte() == expected else { throw .invalidSyntax }
        position += 1
    }

    private mutating func skipWhitespace() {
        while position < length {
            switch byte() {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            default: return
            }
        }
    }

    private func byte(_ offset: Int = 0) -> UInt8 {
        bytes.load(fromByteOffset: position + offset, as: UInt8.self)
    }

    private func slice(_ start: Int, _ end: Int) -> ByteSlice {
        ByteSlice(
            bytes: bytes.advanced(by: start).assumingMemoryBound(to: UInt8.self),
            length: end - start
        )
    }

    private mutating func parseString() throws(NativeJSONError) -> ByteSlice {
        skipWhitespace()
        try expectRaw(0x22)
        let start = position
        while position < length {
            let current = byte()
            if current == 0x22 {
                let result = slice(start, position)
                position += 1
                return result
            }
            if current < 0x20 { throw .invalidString }
            if current == 0x5C {
                position += 1
                guard position < length else { throw .invalidString }
                switch byte() {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    position += 1
                case 0x75:
                    position += 1
                    let scalar = try parseHexQuad()
                    if scalar >= 0xD800 && scalar <= 0xDBFF {
                        guard position + 1 < length, byte() == 0x5C, byte(1) == 0x75 else {
                            throw .invalidString
                        }
                        position += 2
                        let low = try parseHexQuad()
                        guard low >= 0xDC00 && low <= 0xDFFF else { throw .invalidString }
                    } else if scalar >= 0xDC00 && scalar <= 0xDFFF {
                        throw .invalidString
                    }
                default:
                    throw .invalidString
                }
            } else if current < 0x80 {
                position += 1
            } else {
                try consumeUTF8Scalar()
            }
        }
        throw .invalidString
    }

    private mutating func parseHexQuad() throws(NativeJSONError) -> UInt16 {
        guard position + 4 <= length else { throw .invalidString }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let digit: UInt16
            switch byte() {
            case 0x30...0x39: digit = UInt16(byte() - 0x30)
            case 0x41...0x46: digit = UInt16(byte() - 0x41 + 10)
            case 0x61...0x66: digit = UInt16(byte() - 0x61 + 10)
            default: throw .invalidString
            }
            value = value * 16 + digit
            position += 1
        }
        return value
    }

    private mutating func consumeUTF8Scalar() throws(NativeJSONError) {
        let lead = byte()
        let count: Int
        switch lead {
        case 0xC2...0xDF: count = 1
        case 0xE0...0xEF: count = 2
        case 0xF0...0xF4: count = 3
        default: throw .invalidString
        }
        guard position + count < length else { throw .invalidString }
        let first = byte(1)
        if lead == 0xE0 && first < 0xA0 { throw .invalidString }
        if lead == 0xED && first > 0x9F { throw .invalidString }
        if lead == 0xF0 && first < 0x90 { throw .invalidString }
        if lead == 0xF4 && first > 0x8F { throw .invalidString }
        for offset in 1...count where byte(offset) < 0x80 || byte(offset) > 0xBF {
            _ = offset
            throw .invalidString
        }
        position += count + 1
    }

    private mutating func parseUUID() throws(NativeJSONError) -> UUID16 {
        let value = try parseString()
        guard let uuid = UUID16(parsing: value) else { throw .typeMismatch }
        return uuid
    }

    private mutating func parseBool() throws(NativeJSONError) -> Bool {
        skipWhitespace()
        if try consumeLiteral("true") { return true }
        if try consumeLiteral("false") { return false }
        throw .typeMismatch
    }

    private mutating func consumeNull() throws(NativeJSONError) -> Bool {
        skipWhitespace()
        return try consumeLiteral("null")
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws(NativeJSONError) -> Bool {
        guard position + literal.utf8CodeUnitCount <= length else { return false }
        for index in 0..<literal.utf8CodeUnitCount where byte(index) != literal.utf8Start[index] {
            _ = index
            return false
        }
        position += literal.utf8CodeUnitCount
        return true
    }

    private mutating func parseInt() throws(NativeJSONError) -> Int {
        skipWhitespace()
        let start = position
        try parseNumber(integerOnly: true)
        var index = start
        var value = 0
        var negative = false
        if bytes.load(fromByteOffset: index, as: UInt8.self) == 0x2D {
            negative = true
            index += 1
        }
        while index < position {
            let digit = Int(bytes.load(fromByteOffset: index, as: UInt8.self) - 0x30)
            let (product, productOverflow) = value.multipliedReportingOverflow(by: 10)
            let (next, sumOverflow) = negative
                ? product.subtractingReportingOverflow(digit)
                : product.addingReportingOverflow(digit)
            guard !productOverflow, !sumOverflow else { throw .integerOverflow }
            value = next
            index += 1
        }
        return value
    }

    private mutating func parseNumber(integerOnly: Bool) throws(NativeJSONError) {
        guard position < length else { throw .invalidNumber }
        if byte() == 0x2D {
            position += 1
            guard position < length else { throw .invalidNumber }
        }
        if byte() == 0x30 {
            position += 1
            if position < length, byte() >= 0x30, byte() <= 0x39 { throw .invalidNumber }
        } else {
            guard byte() >= 0x31, byte() <= 0x39 else { throw .invalidNumber }
            repeat { position += 1 }
            while position < length && byte() >= 0x30 && byte() <= 0x39
        }
        if position < length, byte() == 0x2E {
            if integerOnly { throw .typeMismatch }
            position += 1
            guard position < length, byte() >= 0x30, byte() <= 0x39 else { throw .invalidNumber }
            repeat { position += 1 }
            while position < length && byte() >= 0x30 && byte() <= 0x39
        }
        if position < length, byte() == 0x65 || byte() == 0x45 {
            if integerOnly { throw .typeMismatch }
            position += 1
            if position < length, byte() == 0x2B || byte() == 0x2D { position += 1 }
            guard position < length, byte() >= 0x30, byte() <= 0x39 else { throw .invalidNumber }
            repeat { position += 1 }
            while position < length && byte() >= 0x30 && byte() <= 0x39
        }
    }

    private mutating func skipValue(depth: Int) throws(NativeJSONError) {
        guard depth <= Self.maximumDepth else { throw .nestingLimit }
        skipWhitespace()
        guard position < length else { throw .invalidSyntax }
        switch byte() {
        case 0x22:
            _ = try parseString()
        case 0x7B:
            position += 1
            skipWhitespace()
            if position < length, byte() == 0x7D { position += 1; return }
            while true {
                _ = try parseString()
                try expect(0x3A)
                try skipValue(depth: depth + 1)
                skipWhitespace()
                guard position < length else { throw .invalidSyntax }
                if byte() == 0x7D { position += 1; break }
                try expectRaw(0x2C)
            }
        case 0x5B:
            position += 1
            skipWhitespace()
            if position < length, byte() == 0x5D { position += 1; return }
            while true {
                try skipValue(depth: depth + 1)
                skipWhitespace()
                guard position < length else { throw .invalidSyntax }
                if byte() == 0x5D { position += 1; break }
                try expectRaw(0x2C)
            }
        case 0x74:
            guard try consumeLiteral("true") else { throw .invalidSyntax }
        case 0x66:
            guard try consumeLiteral("false") else { throw .invalidSyntax }
        case 0x6E:
            guard try consumeLiteral("null") else { throw .invalidSyntax }
        default:
            try parseNumber(integerOnly: false)
        }
    }
}

struct NativeEscapingWriter {
    private let buffer: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private(set) var position = 0

    init(buffer: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buffer = buffer
        self.capacity = capacity
    }

    mutating func writeJSONString(_ value: ByteSlice) throws(WireEncodeError) {
        try write(0x22)
        for index in 0..<value.length {
            guard let byte = value.byte(at: index) else { throw .invalidValue }
            switch byte {
            case 0x22: try writeASCII("\\\"")
            case 0x5C: try writeASCII("\\\\")
            case 0x08: try writeASCII("\\b")
            case 0x0C: try writeASCII("\\f")
            case 0x0A: try writeASCII("\\n")
            case 0x0D: try writeASCII("\\r")
            case 0x09: try writeASCII("\\t")
            case 0x00...0x1F:
                try writeASCII("\\u00")
                try write(Self.hex(byte >> 4))
                try write(Self.hex(byte & 0x0F))
            default:
                try write(byte)
            }
        }
        try write(0x22)
    }

    private mutating func writeASCII(_ value: StaticString) throws(WireEncodeError) {
        for index in 0..<value.utf8CodeUnitCount { try write(value.utf8Start[index]) }
    }

    private mutating func write(_ byte: UInt8) throws(WireEncodeError) {
        guard position < capacity else { throw .bufferOverflow }
        buffer[position] = byte
        position += 1
    }

    private static func hex(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10
    }
}
