// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A format-neutral wire codec bound to one ``WireProfile``.
///
/// The codec is the format seam selected by a transport binding at
/// composition time. It constructs ``WireReader`` and ``WireWriter`` values
/// whose accessor and writer method names stay profile-neutral; the JSON or
/// CBOR engine behind them is selected by ``profile`` and never appears as a
/// conditional in caller code. Every wire DTO therefore decodes and encodes
/// both profiles from one implementation.
///
/// The default engine remains JSON, so a reader or writer constructed
/// directly through ``WireReader`` or ``WireWriter`` keeps the sealed
/// `coaty/3` byte contract.
public struct WireCodec: Sendable, Equatable {
    /// The wire profile whose encoding this codec selects.
    public let profile: WireProfile

    /// Creates a codec for one wire profile.
    ///
    /// - Parameter profile: The profile whose payloads this codec reads and
    ///   writes. The binding selects exactly one profile at composition
    ///   time; there is no per-message negotiation.
    public init(profile: WireProfile) {
        self.profile = profile
    }

    /// Creates a format-neutral reader over borrowed payload bytes.
    ///
    /// `coaty/3` reads tokenize JSON once into bounded borrowed slots;
    /// `axoloty/1` reads index one deterministic CBOR map the same way. The
    /// returned reader borrows the input: use it only while the caller's
    /// buffer stays pinned, and copy any borrowed field before an
    /// asynchronous or isolation-domain boundary.
    ///
    /// - Parameters:
    ///   - bytes: A pointer to the borrowed payload bytes.
    ///   - length: The number of valid payload bytes.
    /// - Returns: A reader over the payload in this codec's format.
    public func reader(bytes: UnsafePointer<UInt8>, length: Int) -> WireReader {
        switch profile {
        case .coaty3JSON:
            #if canImport(_JSONCore)
            return WireReader(bytes: bytes, length: length)
            #else
            preconditionFailure("coaty/3 JSON is unavailable in a CBOR-only build")
            #endif
        case .axoloty1CBOR:
            return WireReader(cborBytes: bytes, length: length)
        }
    }

    /// Creates a format-neutral writer into a caller-owned buffer.
    ///
    /// `coaty/3` writers emit JSON exactly as before; `axoloty/1` writers
    /// emit deterministic CBOR, including the RFC 8949 §4.2.1 map-key order.
    ///
    /// - Parameters:
    ///   - buffer: A caller-owned byte buffer the writer encodes into.
    ///   - capacity: The number of bytes available at `buffer`.
    /// - Returns: A writer into the buffer in this codec's format.
    public func writer(buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> WireWriter {
        switch profile {
        case .coaty3JSON:
            return WireWriter(buffer: buffer, capacity: capacity)
        case .axoloty1CBOR:
            return WireWriter(cborBuffer: buffer, capacity: capacity)
        }
    }

    /// Returns whether a payload is acceptable as a bare IO value.
    ///
    /// `coaty/3` keeps its sealed first-byte sniff: input that can only be
    /// JSON must be well-formed JSON, and bytes that cannot be JSON are
    /// accepted as external raw input. `axoloty/1` has no first-byte sniff —
    /// every byte value opens a legal CBOR item, and external IO routes carry
    /// application-defined bytes — so the bare-value gate is the caller's
    /// bounded decode and this method accepts the payload.
    ///
    /// - Parameter payload: The borrowed bare-value payload to accept.
    /// - Returns: Whether the payload passes the profile's bare-value gate.
    public func isValidBareValue(_ payload: ByteSlice) -> Bool {
        switch profile {
        case .coaty3JSON:
            #if canImport(_JSONCore)
            guard let first = payload.byte(at: 0) else { return true }
            switch first {
            case 0x22, 0x2D, 0x30...0x39, 0x5B, 0x66, 0x6E, 0x74, 0x7B:
                return WireReader.isValidJSONValue(payload)
            default:
                return true
            }
            #else
            preconditionFailure("coaty/3 JSON is unavailable in a CBOR-only build")
            #endif
        case .axoloty1CBOR:
            return true
        }
    }

    /// Copies string content after the profile's string decoding.
    ///
    /// `coaty/3` string content carries JSON escape sequences, which are
    /// decoded while copying. `axoloty/1` string content is plain UTF-8,
    /// which is validated while copying.
    ///
    /// - Parameters:
    ///   - content: The borrowed string content returned by
    ///     ``WireReader/readString(_:)``.
    ///   - output: Fixed storage receiving the decoded UTF-8 bytes.
    /// - Returns: The number of decoded bytes written.
    /// - Throws: ``WireDecodeError`` for malformed escapes, invalid UTF-8,
    ///   or capacity exhaustion.
    public func copyDecodedString<let capacity: Int>(
        _ content: ByteSlice,
        into output: inout InlineArray<capacity, UInt8>
    ) throws(WireDecodeError) -> Int {
        switch profile {
        case .coaty3JSON:
            #if canImport(_JSONCore)
            return try content.copyDecodedJSONString(into: &output)
            #else
            throw WireDecodeError(.invalidValue)
            #endif
        case .axoloty1CBOR:
            guard content.isValidUTF8() else {
                throw WireDecodeError(.invalidUTF8, byteOffset: content.length)
            }
            guard content.length <= capacity else {
                throw WireDecodeError(.payloadExceedsLimit, byteOffset: content.length)
            }
            content.withBytes { pointer, count in
                for index in 0..<count {
                    output[index] = pointer.load(fromByteOffset: index, as: UInt8.self)
                }
            }
            return content.length
        }
    }
}
