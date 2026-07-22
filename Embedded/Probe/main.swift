// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A minimal writer used to prove the non-existential Embedded Swift seam.
public struct JSONWriter {
    /// The bytes emitted so far.
    public private(set) var bytes: [UInt8] = []

    /// Creates an empty writer.
    public init() {}

    /// Writes a UTF-8 JSON fragment.
    public mutating func write(_ fragment: String) {
        bytes.append(contentsOf: fragment.utf8)
    }
}

/// Encodes a value without `Codable`, existential encoders, or reflection.
public protocol WireEncodable {
    /// Encodes this value into the supplied writer.
    func encode(to writer: inout JSONWriter)
}

/// A first statically-typed payload for the Linux Embedded Swift prototype.
public struct EmbeddedLog: WireEncodable {
    /// The log message.
    public let message: String

    /// Creates a log payload.
    public init(message: String) {
        self.message = message
    }

    /// Encodes the payload in the stable JSON wire shape.
    public func encode(to writer: inout JSONWriter) {
        writer.write("{\"message\":\"")
        writer.write(message)
        writer.write("\"}")
    }
}

@main
struct EmbeddedProbe {
    static func main() {
        var writer = JSONWriter()
        EmbeddedLog(message: "embedded").encode(to: &writer)
        print(String(decoding: writer.bytes, as: UTF8.self))
    }
}
