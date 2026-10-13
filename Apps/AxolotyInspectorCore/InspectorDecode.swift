// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The byte source for a local inspector `decode` command.
public enum InspectorDecodeSource: Equatable, Sendable {
    /// Raw payload bytes given as a hexadecimal string.
    case hex(String)
    /// Raw payload bytes given as a base64 string.
    case base64(String)
    /// Raw payload bytes read from a file path.
    case file(String)
}

/// The rendering mode for a local inspector `decode` command.
public enum InspectorDecodeRender: String, Equatable, Sendable {
    /// RFC 8949 §8 diagnostic notation for CBOR, or the JSON text unchanged.
    case diagnostic
    /// Sorted JSON, either projected from CBOR or normalized from JSON.
    case json
}

/// Options for the local `decode` command.
///
/// The command is broker-independent: it reads a payload the operator already
/// holds and renders it, so an inspector can read an `axoloty/1` CBOR payload
/// without a live connection.
public struct DecodeCommand: Equatable, Sendable {
    /// Where the payload bytes come from.
    public let source: InspectorDecodeSource
    /// How to render the decoded payload.
    public let render: InspectorDecodeRender
    /// The declared payload encoding, or `.auto` to detect.
    public let encoding: InspectorPayloadEncoding

    /// Creates decode command options.
    ///
    /// - Parameters:
    ///   - source: The byte source.
    ///   - render: The rendering mode.
    ///   - encoding: The declared payload encoding, or `.auto` to detect.
    public init(
        source: InspectorDecodeSource,
        render: InspectorDecodeRender = .diagnostic,
        encoding: InspectorPayloadEncoding = .auto
    ) {
        self.source = source
        self.render = render
        self.encoding = encoding
    }
}

/// A structured failure while decoding a payload for the `decode` command.
public enum InspectorDecodeError: Error, Equatable, Sendable {
    /// The hexadecimal source contained a non-hexadecimal character.
    case invalidHex
    /// The base64 source could not be decoded.
    case invalidBase64
    /// The file source could not be read.
    case unreadableFile(reason: String)
    /// The payload contained no bytes.
    case emptyPayload
    /// The payload was neither JSON nor a single valid CBOR item.
    case unsupportedPayload
    /// A CBOR payload could not be projected into a JSON object.
    case notAJSONMap

    /// A stable, operator-facing message for the failure.
    public var userFriendlyMessage: String {
        switch self {
        case .invalidHex:
            return "invalid hexadecimal payload"
        case .invalidBase64:
            return "invalid base64 payload"
        case .unreadableFile(let reason):
            return "cannot read payload file: \(reason)"
        case .emptyPayload:
            return "payload is empty"
        case .unsupportedPayload:
            return "payload is neither JSON nor a single valid CBOR item"
        case .notAJSONMap:
            return "CBOR payload is not a map that can be rendered as JSON"
        }
    }
}

/// Reads and renders a payload for the local `decode` command.
public enum InspectorDecodeRunner {
    /// Resolves a decode source into payload bytes.
    ///
    /// - Parameter source: The byte source.
    /// - Returns: The payload bytes.
    /// - Throws: ``InspectorDecodeError`` when the source cannot be read.
    public static func bytes(for source: InspectorDecodeSource) throws(InspectorDecodeError) -> [UInt8] {
        switch source {
        case .hex(let text):
            return try hexadecimalBytes(text)
        case .base64(let text):
            guard let data = Data(base64Encoded: text) else { throw .invalidBase64 }
            return [UInt8](data)
        case .file(let path):
            do {
                return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                throw .unreadableFile(reason: error.localizedDescription)
            }
        }
    }

    /// Renders a decoded payload as diagnostic notation or JSON.
    ///
    /// JSON payloads pass through unchanged for diagnostic rendering and are
    /// normalized to sorted JSON for JSON rendering. CBOR payloads are decoded
    /// with ``InspectorCBORCodec``.
    ///
    /// - Parameter command: The decode command.
    /// - Returns: The rendered payload text.
    /// - Throws: ``InspectorDecodeError`` when the payload cannot be rendered.
    public static func render(_ command: DecodeCommand) throws(InspectorDecodeError) -> String {
        let payload = try bytes(for: command.source)
        guard !payload.isEmpty else { throw .emptyPayload }

        let codec = InspectorCBORCodec()
        switch command.render {
        case .diagnostic:
            switch codec.format(of: payload, encoding: command.encoding) {
            case .cbor:
                do {
                    return try codec.diagnosticNotation(of: payload)
                } catch {
                    throw .unsupportedPayload
                }
            case .json:
                return String(decoding: payload, as: UTF8.self)
            case .unknown:
                throw .unsupportedPayload
            }
        case .json:
            switch codec.format(of: payload, encoding: command.encoding) {
            case .cbor:
                guard let text = codec.jsonText(of: payload) else { throw .notAJSONMap }
                return text
            case .json:
                return try normalizedJSON(payload)
            case .unknown:
                throw .unsupportedPayload
            }
        }
    }

    private static func hexadecimalBytes(_ text: String) throws(InspectorDecodeError) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(text.count / 2)
        var high: UInt8?
        for character in text {
            if character.isWhitespace { continue }
            guard let nibble = character.hexDigitValue else { throw .invalidHex }
            if let pending = high {
                output.append((pending << 4) | UInt8(nibble))
                high = nil
            } else {
                high = UInt8(nibble)
            }
        }
        guard high == nil else { throw .invalidHex }
        return output
    }

    private static func normalizedJSON(_ payload: [UInt8]) throws(InspectorDecodeError) -> String {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(payload),
            options: [.fragmentsAllowed]
        ),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else {
            throw .unsupportedPayload
        }
        return String(decoding: data, as: UTF8.self)
    }
}
