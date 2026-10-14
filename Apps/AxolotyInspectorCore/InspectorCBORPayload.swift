// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The payload encoding observed on a wire frame.
///
/// The route prefix is the authoritative `axoloty/1` encoding signal on MQTT.
/// The inspector derives this classification from the bytes only because a
/// diagnostic tool may hold a payload whose route it did not capture.
public enum InspectorPayloadFormat: String, Codable, Sendable, Equatable {
    /// UTF-8 JSON, the `coaty/3` encoding.
    case json
    /// CBOR, the `axoloty/1` encoding.
    case cbor
    /// Neither JSON nor a single valid CBOR item.
    case unknown
}

/// Caller-declared payload encoding for a local decode.
///
/// Auto detection is a convenience, not an authority. A short byte string can
/// be valid JSON and valid CBOR at the same time: `0x30` is the JSON number
/// `0` and the CBOR negative integer `-17`, and `0x31` is the JSON number `1`
/// and the CBOR negative integer `-18`. A caller that knows the source profile
/// declares it and skips detection.
public enum InspectorPayloadEncoding: String, Codable, Sendable, Equatable, CaseIterable {
    /// Detect JSON first, then CBOR.
    case auto
    /// Treat the payload as `coaty/3` JSON.
    case json
    /// Treat the payload as `axoloty/1` CBOR.
    case cbor
}

/// Reads and writes CBOR payloads for inspector output.
///
/// The codec composes the bounded ``CBORDecoder`` with the diagnostic-notation
/// renderer and a JSON projection. The projection lets the existing inspector
/// JSON decode paths consume an `axoloty/1` payload without a second schema.
public struct InspectorCBORCodec: Sendable {
    /// Creates a codec.
    public init() {}

    /// Classifies a payload as JSON, CBOR, or unknown.
    ///
    /// Detection is inherently ambiguous for short inputs. `0x30` is the JSON
    /// number `0` and the CBOR negative integer `-17`; `0x31` is the JSON
    /// number `1` and the CBOR negative integer `-18`. Auto mode resolves that
    /// ambiguity by testing JSON first, which matches the `coaty/3` profile.
    /// The ordering is a deterministic tie-break, not a proof. Declare
    /// `encoding` when the source profile is known.
    ///
    /// - Parameters:
    ///   - bytes: The payload bytes.
    ///   - encoding: The declared encoding, or `.auto` to detect.
    /// - Returns: The detected payload format.
    public func format(
        of bytes: [UInt8],
        encoding: InspectorPayloadEncoding = .auto
    ) -> InspectorPayloadFormat {
        guard !bytes.isEmpty else { return .unknown }
        switch encoding {
        case .json:
            return Self.isJSON(bytes) ? .json : .unknown
        case .cbor:
            return Self.isCBOR(bytes) ? .cbor : .unknown
        case .auto:
            if Self.isJSON(bytes) { return .json }
            if Self.isCBOR(bytes) { return .cbor }
            return .unknown
        }
    }

    /// Decodes a single CBOR item.
    ///
    /// - Parameter bytes: The payload bytes.
    /// - Returns: The decoded value.
    /// - Throws: ``CBORDecodingError`` when the bytes are not a single valid
    ///   CBOR data item.
    public func decodedValue(of bytes: [UInt8]) throws(CBORDecodingError) -> CBORValue {
        var decoder = CBORDecoder(bytes)
        return try decoder.decode()
    }

    /// Renders a CBOR payload as RFC 8949 §8 diagnostic notation.
    ///
    /// - Parameter bytes: The CBOR payload bytes.
    /// - Returns: The diagnostic-notation text.
    /// - Throws: ``CBORDecodingError`` when the bytes are not a single valid
    ///   CBOR data item.
    public func diagnosticNotation(of bytes: [UInt8]) throws(CBORDecodingError) -> String {
        CBORDiagnosticNotation.render(try decodedValue(of: bytes))
    }

    /// Projects a CBOR payload into a Foundation JSON object.
    ///
    /// - Parameter bytes: The CBOR payload bytes.
    /// - Returns: A dictionary when the payload is a CBOR map, otherwise
    ///   `nil`.
    public func jsonObject(of bytes: [UInt8]) -> [String: Any]? {
        guard let value = try? decodedValue(of: bytes) else { return nil }
        return jsonValue(from: value) as? [String: Any]
    }

    /// Encodes JSON text from a CBOR payload, sorted by key.
    ///
    /// - Parameter bytes: The CBOR payload bytes.
    /// - Returns: Sorted JSON text, or `nil` when the payload cannot be
    ///   projected.
    public func jsonText(of bytes: [UInt8]) -> String? {
        guard let object = jsonObject(of: bytes) else { return nil }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Projects a decoded value into JSON-compatible Foundation values.
    ///
    /// Tag 37 byte strings become canonical UUID text so an inspector can read
    /// an `axoloty/1` object identifier without CBOR knowledge. Other tags
    /// project their wrapped value. Byte strings become base64 text.
    ///
    /// - Parameter value: The decoded CBOR value.
    /// - Returns: A JSON-compatible value.
    public func jsonValue(from value: CBORValue) -> Any {
        switch value {
        case .unsigned(let number):
            return number <= UInt64(Int.max) ? Int(number) : NSNumber(value: number)
        case .negative(let argument):
            if argument <= UInt64(Int.max) {
                return Int(-1 - Int(argument))
            }
            return CBORDiagnosticNotation.render(value)
        case .byteString(let bytes):
            return base64(bytes)
        case .textString(let text):
            return text
        case .chunkedByteString(let chunks):
            return base64(chunks.flatMap { $0 })
        case .chunkedTextString(let chunks):
            return chunks.joined()
        case .array(let items, _):
            return items.map { jsonValue(from: $0) }
        case .map(let entries, _):
            var object: [String: Any] = [:]
            for entry in entries {
                object[jsonKey(from: entry.key)] = jsonValue(from: entry.value)
            }
            return object
        case .tag(37, let inner):
            if let bytes = inner.bytesValue, bytes.count == 16 {
                return Self.uuidString(bytes)
            }
            return jsonValue(from: inner)
        case .tag(_, let inner):
            return jsonValue(from: inner)
        case .simple(let simple):
            return Int(simple)
        case .boolean(let flag):
            return flag
        case .null:
            return NSNull()
        case .undefined:
            return NSNull()
        case .float(let number):
            return number
        }
    }

    private func jsonKey(from key: CBORValue) -> String {
        if let text = key.textValue { return text }
        switch key {
        case .tag(37, let inner):
            if let bytes = inner.bytesValue, bytes.count == 16 {
                return Self.uuidString(bytes)
            }
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        default:
            break
        }
        return CBORDiagnosticNotation.render(key)
    }

    private func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    private static func isJSON(_ bytes: [UInt8]) -> Bool {
        guard looksLikeJSON(bytes) else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) != nil
    }

    private static func isCBOR(_ bytes: [UInt8]) -> Bool {
        var decoder = CBORDecoder(bytes)
        return (try? decoder.decode()) != nil
    }

    private static func looksLikeJSON(_ bytes: [UInt8]) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        let first = bytes.first { !whitespace.contains($0) }
        guard let first else { return false }
        if first == 0x7B || first == 0x5B || first == 0x22 || first == 0x2D {
            return true
        }
        if (0x30...0x39).contains(first) { return true }
        return first == 0x74 || first == 0x66 || first == 0x6E
    }

    /// Formats 16 bytes as a canonical uppercase UUID string.
    static func uuidString(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let hyphenOffsets: Set<Int> = [8, 12, 16, 20]
        var result = ""
        result.reserveCapacity(36)
        for (offset, character) in hex.enumerated() {
            if hyphenOffsets.contains(offset) { result.append("-") }
            result.append(character)
        }
        return result
    }
}
