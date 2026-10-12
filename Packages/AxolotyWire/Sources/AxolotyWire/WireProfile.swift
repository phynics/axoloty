// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A versioned wire profile carried on the route prefix.
///
/// A profile pairs a protocol name and version (the first two topic levels)
/// with the payload encoding a binding must use. In version 1 each transport
/// binding selects exactly one profile at composition time; the runtime never
/// negotiates or switches profiles per message.
///
/// * ``coaty3JSON`` — `coaty/3`, UTF-8 JSON payloads. The Coaty Core Profile 3
///   contract kept for CoatyJS interoperability on MQTT.
/// * ``axoloty1CBOR`` — `axoloty/1`, deterministic CBOR (RFC 8949) payloads.
///   The Embedded Swift and Zenoh profile.
///
/// The route prefix is the authoritative encoding signal. A transport's
/// content-type hint (for example a Zenoh `Encoding` value) is advisory and
/// never changes how the payload is decoded.
public enum WireProfile: Sendable, Equatable, CaseIterable {
    /// `coaty/3` with JSON payloads.
    case coaty3JSON
    /// `axoloty/1` with deterministic CBOR payloads.
    case axoloty1CBOR

    /// The protocol name written as topic level 0 (for example `coaty`).
    public var protocolName: StaticString {
        switch self {
        case .coaty3JSON: return "coaty"
        case .axoloty1CBOR: return "axoloty"
        }
    }

    /// The protocol version written as topic level 1 (for example `3`).
    public var protocolVersion: StaticString {
        switch self {
        case .coaty3JSON: return "3"
        case .axoloty1CBOR: return "1"
        }
    }

    /// The advisory payload content type for this profile.
    public var contentType: StaticString {
        switch self {
        case .coaty3JSON: return "application/json"
        case .axoloty1CBOR: return "application/cbor"
        }
    }

    /// Matches a route's protocol name and version levels to a known profile.
    ///
    /// - Parameters:
    ///   - protocolName: Topic level 0, for example `coaty`.
    ///   - protocolVersion: Topic level 1, for example `3`.
    public init?(protocolName: ByteSlice, protocolVersion: ByteSlice) {
        if protocolName.equals("coaty"), protocolVersion.equals("3") {
            self = .coaty3JSON
        } else if protocolName.equals("axoloty"), protocolVersion.equals("1") {
            self = .axoloty1CBOR
        } else {
            return nil
        }
    }
}
