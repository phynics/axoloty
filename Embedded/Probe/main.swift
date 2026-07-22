// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A minimal JSON writer used to prove the non-existential Embedded Swift seam.
public struct JSONWriter {
    /// The bytes emitted so far.
    public private(set) var bytes: [UInt8] = []

    /// Creates an empty writer.
    public init() {}

    /// Writes a JSON string, including quotes and required escapes.
    public mutating func writeString(_ value: String) {
        bytes.append(34)
        for byte in value.utf8 {
            switch byte {
            case 8: bytes.append(contentsOf: [92, 98])
            case 9: bytes.append(contentsOf: [92, 116])
            case 10: bytes.append(contentsOf: [92, 110])
            case 12: bytes.append(contentsOf: [92, 102])
            case 13: bytes.append(contentsOf: [92, 114])
            case 34, 92:
                bytes.append(92)
                bytes.append(byte)
            default:
                bytes.append(byte)
            }
        }
        bytes.append(34)
    }

    /// Writes a UTF-8 JSON fragment.
    public mutating func write(_ fragment: String) {
        bytes.append(contentsOf: fragment.utf8)
    }
}

/// A small cursor-based JSON reader for statically typed payload decoders.
public struct JSONReader {
    private let bytes: [UInt8]
    private var index: Int = 0

    /// Creates a reader over UTF-8 JSON bytes.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Reads a string value from an object member with the supplied key.
    public mutating func readString(for key: String) -> String? {
        guard skipWhitespace(), consume(123), skipWhitespace(),
              let actualKey = readString(), wireUTF8Equal(actualKey, key),
              skipWhitespace(), consume(58), skipWhitespace(),
              let value = readString(), skipWhitespace(), consume(125) else {
            return nil
        }
        _ = skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private mutating func readString() -> String? {
        guard consume(34) else { return nil }
        var value: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                return String(decoding: value, as: UTF8.self)
            }
            if byte == 92 {
                guard index < bytes.count else { return nil }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case 34, 47, 92: value.append(escaped)
                case 98: value.append(8)
                case 102: value.append(12)
                case 110: value.append(10)
                case 114: value.append(13)
                case 116: value.append(9)
                default: return nil
                }
            } else {
                guard byte >= 32 else { return nil }
                value.append(byte)
            }
        }
        return nil
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() -> Bool {
        while index < bytes.count {
            switch bytes[index] {
            case 9, 10, 13, 32: index += 1
            default: return true
            }
        }
        return true
    }
}

/// Encodes a value without `Codable`, existential encoders, or reflection.
public protocol WireEncodable {
    /// Encodes this value into the supplied writer.
    func encode(to writer: inout JSONWriter)
}

/// Decodes a value without `Codable`, existential decoders, or reflection.
///
/// Embedded Swift cannot materialize an `any Error` existential for `throws`,
/// so malformed input is reported through a failable initializer.
public protocol WireDecodable {
    /// Creates a value from the supplied reader, or returns `nil` on invalid input.
    init?(from reader: inout JSONReader)
}

/// A value supporting both embedded wire directions.
public protocol WireCodable: WireEncodable, WireDecodable {}

func wireUTF8Equal(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    for index in 0..<left.count where left[index] != right[index] {
        return false
    }
    return true
}

/// A first statically typed payload for the Linux Embedded Swift prototype.
public struct EmbeddedLog: WireCodable {
    /// The log message.
    public let message: String

    /// Creates a log payload.
    public init(message: String) {
        self.message = message
    }

    /// Decodes the payload in the stable JSON wire shape.
    public init?(from reader: inout JSONReader) {
        guard let message = reader.readString(for: "message") else { return nil }
        self.message = message
    }

    /// Encodes the payload in the stable JSON wire shape.
    public func encode(to writer: inout JSONWriter) {
        writer.write("{\"message\":")
        writer.writeString(message)
        writer.write("}")
    }
}

@main
struct EmbeddedProbe {
    static func main() {
        var writer = JSONWriter()
        EmbeddedLog(message: "embedded").encode(to: &writer)
        var reader = JSONReader(bytes: writer.bytes)
        guard let decoded = EmbeddedLog(from: &reader), wireUTF8Equal(decoded.message, "embedded") else {
            fatalError()
        }
        print(String(decoding: writer.bytes, as: UTF8.self))
    }
}
