// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A diagnostic-notation parse failure.
public enum CBORParseError: Error, Equatable, Sendable {
    /// The input ended before the value was complete.
    case unexpectedEnd
    /// An unexpected character appeared.
    case unexpectedCharacter(Character)
    /// A numeric literal was malformed or out of range.
    case invalidNumber(String)
    /// A byte-string literal was malformed.
    case invalidByteString
    /// A text-string literal was malformed.
    case invalidTextString
    /// A tag literal was malformed.
    case invalidTag
    /// Byte and text chunks were mixed in one indefinite-length string.
    case mixedStringChunks
    /// Bytes remained after the first complete value.
    case trailingCharacters
    /// Nesting exceeded the profile depth bound.
    case nestingTooDeep
}

/// Renders and parses RFC 8949 §8 diagnostic notation.
///
/// The renderer emits the canonical notation used in the RFC: `h'...'` for
/// byte strings, quoted text for text strings, `[_ ...]` and `{_ ...}` for
/// indefinite-length containers, `(_ ...)` for indefinite-length strings,
/// `tag(value)` for tags, and `NaN`/`Infinity`/`-Infinity` for non-finite
/// floats.
///
/// The parser accepts that same notation, including definite-length
/// equivalents, so a diagnostic string can be edited and encoded back to
/// deterministic CBOR.
public enum CBORDiagnosticNotation {
    /// Renders a value as diagnostic notation.
    ///
    /// - Parameter value: The value to render.
    /// - Returns: The diagnostic-notation text.
    public static func render(_ value: CBORValue) -> String {
        render(value, depth: 0)
    }

    /// Encodes CBOR bytes as diagnostic notation.
    ///
    /// - Parameter bytes: The CBOR bytes to decode and render.
    /// - Returns: The diagnostic-notation text.
    /// - Throws: ``CBORDecodingError`` when the bytes are not a single valid
    ///   CBOR data item.
    public static func render(bytes: [UInt8]) throws(CBORDecodingError) -> String {
        var decoder = CBORDecoder(bytes)
        return render(try decoder.decode())
    }

    /// Parses diagnostic notation into a value.
    ///
    /// - Parameter text: The diagnostic-notation text.
    /// - Returns: The parsed value.
    /// - Throws: ``CBORParseError`` when the text is malformed.
    public static func parse(_ text: String) throws(CBORParseError) -> CBORValue {
        var parser = Parser(characters: Array(text))
        let value = try parser.parseItem()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw CBORParseError.trailingCharacters }
        return value
    }

    // MARK: - Rendering

    private static func render(_ value: CBORValue, depth: Int) -> String {
        switch value {
        case .unsigned(let number):
            return String(number)
        case .negative(let argument):
            return negativeDescription(argument)
        case .byteString(let bytes):
            return "h'" + hex(bytes) + "'"
        case .textString(let text):
            return quoted(text)
        case .chunkedByteString(let chunks):
            return "(_ " + chunks.map { "h'" + hex($0) + "'" }.joined(separator: ", ") + ")"
        case .chunkedTextString(let chunks):
            return "(_ " + chunks.map(quoted).joined(separator: ", ") + ")"
        case .array(let items, let indefinite):
            let inner = items.map { render($0, depth: depth + 1) }.joined(separator: ", ")
            return indefinite ? "[_ " + inner + "]" : "[" + inner + "]"
        case .map(let entries, let indefinite):
            let inner = entries.map {
                render($0.key, depth: depth + 1) + ": " + render($0.value, depth: depth + 1)
            }.joined(separator: ", ")
            return indefinite ? "{_ " + inner + "}" : "{" + inner + "}"
        case .tag(let tag, let inner):
            return String(tag) + "(" + render(inner, depth: depth + 1) + ")"
        case .simple(let simple):
            return "simple(" + String(simple) + ")"
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case .undefined:
            return "undefined"
        case .float(let number):
            return floatDescription(number)
        }
    }

    private static func negativeDescription(_ argument: UInt64) -> String {
        if argument == UInt64.max {
            return "-18446744073709551616"
        }
        return "-" + String(argument + 1)
    }

    private static func floatDescription(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number == .infinity { return "Infinity" }
        if number == -.infinity { return "-Infinity" }
        return String(number)
    }

    private static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - Parsing

    private struct Parser {
        let characters: [Character]
        var index = 0

        var isAtEnd: Bool { index >= characters.count }

        var current: Character? { index < characters.count ? characters[index] : nil }

        func peek(_ offset: Int) -> Character? {
            let target = index + offset
            return target < characters.count ? characters[target] : nil
        }

        mutating func skipWhitespace() {
            while let character = current, character == " " || character == "\t" || character == "\n" || character == "\r" {
                index += 1
            }
        }

        mutating func match(_ character: Character) -> Bool {
            guard current == character else { return false }
            index += 1
            return true
        }

        mutating func expect(_ character: Character) throws(CBORParseError) {
            guard match(character) else {
                guard let current else { throw CBORParseError.unexpectedEnd }
                throw CBORParseError.unexpectedCharacter(current)
            }
        }

        mutating func matchKeyword(_ keyword: String) -> Bool {
            let keywordCharacters = Array(keyword)
            guard index + keywordCharacters.count <= characters.count else { return false }
            for (offset, character) in keywordCharacters.enumerated() {
                guard characters[index + offset] == character else { return false }
            }
            if let boundary = peek(keywordCharacters.count), boundary.isLetter || boundary.isNumber || boundary == "_" {
                return false
            }
            index += keywordCharacters.count
            return true
        }

        mutating func parseItem(depth: Int = 0) throws(CBORParseError) -> CBORValue {
            guard depth <= CBORDecodeLimits.profile.maximumDepth else { throw CBORParseError.nestingTooDeep }
            skipWhitespace()
            guard let character = current else { throw CBORParseError.unexpectedEnd }
            switch character {
            case "[": return try parseArray(depth: depth)
            case "{": return try parseMap(depth: depth)
            case "(": return try parseChunkedString()
            case "\"": return .textString(try parseQuotedString())
            case "h" where peek(1) == "'": return .byteString(try parseByteString())
            case "-":
                if matchKeyword("-Infinity") { return .float(-.infinity) }
                return try parseNumber(depth: depth)
            case "t":
                if matchKeyword("true") { return .boolean(true) }
            case "f":
                if matchKeyword("false") { return .boolean(false) }
            case "n":
                if matchKeyword("null") { return .null }
            case "u":
                if matchKeyword("undefined") { return .undefined }
            case "N":
                if matchKeyword("NaN") { return .float(.nan) }
            case "I":
                if matchKeyword("Infinity") { return .float(.infinity) }
            case "s":
                if matchKeyword("simple") { return try parseSimple() }
            default:
                break
            }
            if character.isNumber { return try parseNumber(depth: depth) }
            throw CBORParseError.unexpectedCharacter(character)
        }

        mutating func parseArray(depth: Int) throws(CBORParseError) -> CBORValue {
            try expect("[")
            skipWhitespace()
            let indefinite = match("_")
            skipWhitespace()
            var items: [CBORValue] = []
            if match("]") { return .array(items, indefinite: indefinite) }
            while true {
                items.append(try parseItem(depth: depth + 1))
                skipWhitespace()
                if match("]") { break }
                try expect(",")
            }
            return .array(items, indefinite: indefinite)
        }

        mutating func parseMap(depth: Int) throws(CBORParseError) -> CBORValue {
            try expect("{")
            skipWhitespace()
            let indefinite = match("_")
            skipWhitespace()
            var entries: [CBORMapEntry] = []
            if match("}") { return .map(entries, indefinite: indefinite) }
            while true {
                let key = try parseItem(depth: depth + 1)
                skipWhitespace()
                try expect(":")
                let value = try parseItem(depth: depth + 1)
                entries.append(CBORMapEntry(key: key, value: value))
                skipWhitespace()
                if match("}") { break }
                try expect(",")
            }
            return .map(entries, indefinite: indefinite)
        }

        mutating func parseChunkedString() throws(CBORParseError) -> CBORValue {
            try expect("(")
            skipWhitespace()
            try expect("_")
            skipWhitespace()
            var byteChunks: [[UInt8]] = []
            var textChunks: [String] = []
            var expectsBytes: Bool?
            while true {
                skipWhitespace()
                if match(")") { break }
                if current == "h", peek(1) == "'" {
                    guard expectsBytes != false else { throw CBORParseError.mixedStringChunks }
                    expectsBytes = true
                    byteChunks.append(try parseByteString())
                } else if current == "\"" {
                    guard expectsBytes != true else { throw CBORParseError.mixedStringChunks }
                    expectsBytes = false
                    textChunks.append(try parseQuotedString())
                } else {
                    guard let current else { throw CBORParseError.unexpectedEnd }
                    throw CBORParseError.unexpectedCharacter(current)
                }
                skipWhitespace()
                if match(")") { break }
                try expect(",")
            }
            return expectsBytes == true ? .chunkedByteString(byteChunks) : .chunkedTextString(textChunks)
        }

        mutating func parseByteString() throws(CBORParseError) -> [UInt8] {
            try expect("h")
            try expect("'")
            var digits: [Character] = []
            while let character = current, character != "'" {
                digits.append(character)
                index += 1
            }
            try expect("'")
            guard digits.count % 2 == 0 else { throw CBORParseError.invalidByteString }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(digits.count / 2)
            var highNibble: UInt8?
            for digit in digits {
                guard let nibble = digit.hexDigitValue else { throw CBORParseError.invalidByteString }
                if let high = highNibble {
                    bytes.append((high << 4) | UInt8(nibble))
                    highNibble = nil
                } else {
                    highNibble = UInt8(nibble)
                }
            }
            return bytes
        }

        mutating func parseQuotedString() throws(CBORParseError) -> String {
            try expect("\"")
            var result = ""
            while let character = current {
                index += 1
                if character == "\"" {
                    return result
                }
                if character != "\\" {
                    result.append(character)
                    continue
                }
                guard let escaped = current else { throw CBORParseError.invalidTextString }
                index += 1
                switch escaped {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u": result.unicodeScalars.append(try parseUnicodeEscape())
                default: throw CBORParseError.invalidTextString
                }
            }
            throw CBORParseError.unexpectedEnd
        }

        mutating func parseUnicodeEscape() throws(CBORParseError) -> Unicode.Scalar {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let character = current, let digit = character.hexDigitValue else {
                    throw CBORParseError.invalidTextString
                }
                index += 1
                value = (value << 4) | UInt32(digit)
            }
            guard let scalar = Unicode.Scalar(value) else { throw CBORParseError.invalidTextString }
            return scalar
        }

        mutating func parseSimple() throws(CBORParseError) -> CBORValue {
            try expect("(")
            skipWhitespace()
            let digits = readDigits()
            guard !digits.isEmpty, let value = UInt8(digits) else {
                throw CBORParseError.invalidNumber(digits)
            }
            skipWhitespace()
            try expect(")")
            return .simple(value)
        }

        mutating func parseNumber(depth: Int) throws(CBORParseError) -> CBORValue {
            let start = index
            let negative = match("-")
            let digits = readDigits()
            guard !digits.isEmpty else { throw CBORParseError.invalidNumber(String(characters[start..<index])) }
            var isFloat = false
            if match(".") {
                isFloat = true
                let fraction = readDigits()
                guard !fraction.isEmpty else { throw CBORParseError.invalidNumber(String(characters[start..<index])) }
            }
            if current == "e" || current == "E" {
                isFloat = true
                index += 1
                _ = match("+") || match("-")
                let exponent = readDigits()
                guard !exponent.isEmpty else { throw CBORParseError.invalidNumber(String(characters[start..<index])) }
            }
            let token = String(characters[start..<index])
            if isFloat {
                guard let number = Double(token) else { throw CBORParseError.invalidNumber(token) }
                return .float(number)
            }
            if match("(") {
                guard !negative, let tag = UInt64(digits) else { throw CBORParseError.invalidTag }
                let inner = try parseItem(depth: depth + 1)
                skipWhitespace()
                try expect(")")
                return .tag(tag, inner)
            }
            if negative {
                if digits == "0" { return .unsigned(0) }
                if let magnitude = UInt64(digits) { return .negative(magnitude - 1) }
                if digits == "18446744073709551616" { return .negative(UInt64.max) }
                throw CBORParseError.invalidNumber(token)
            }
            guard let value = UInt64(digits) else { throw CBORParseError.invalidNumber(token) }
            return .unsigned(value)
        }

        mutating func readDigits() -> String {
            let start = index
            while let character = current, character.isNumber {
                index += 1
            }
            return String(characters[start..<index])
        }
    }
}
