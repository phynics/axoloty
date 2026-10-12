// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Foundation-free decode protocol for wire types.
///
/// Types conforming to `WireDecodable` decode from a format-neutral
/// `WireReader` without `Codable`, `Foundation`, `Any`, reflection, or
/// intermediate value trees. The reader provides typed field access by static
/// string key; string values are returned as borrowed `ByteSlice` (no String
/// allocation). A reader constructed through ``WireCodec`` selects the
/// `coaty/3` JSON engine or the `axoloty/1` CBOR engine, so one conformance
/// decodes both profiles.
///
/// Host and static runtime paths consume this same protocol. Package tests
/// exercise DTO round trips, malformed input, and bounded-buffer failures
/// directly at this portable boundary.
public protocol WireDecodable {
    /// Creates an instance by decoding fields from `reader`.
    ///
    /// - Parameter reader: A ``WireReader`` over the payload bytes in the
    ///   decoding profile's format.
    /// - Throws: ``WireDecodeError`` if a required field is missing or malformed.
    init(from reader: WireReader) throws(WireDecodeError)
}

/// Foundation-free encode protocol for wire types.
///
/// Types conforming to `WireEncodable` encode into a caller-provided
/// format-neutral `WireWriter` buffer without `Codable` or `Foundation`. A
/// writer constructed through ``WireCodec`` emits `coaty/3` JSON or
/// `axoloty/1` deterministic CBOR, so one conformance encodes both profiles.
public protocol WireEncodable {
    /// Encodes this value into the given writer's buffer.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the encoded output exceeds the buffer capacity.
    func encode(to writer: inout WireWriter) throws(WireEncodeError)
}
