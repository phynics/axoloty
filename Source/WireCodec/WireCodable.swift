// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Foundation-free decode protocol for wire types.
///
/// Types conforming to `WireDecodable` decode from a `WireReader` without
/// `Codable`, `Foundation`, `Any`, reflection, or intermediate JSON value
/// trees. The reader provides typed field access by static string key;
/// string values are returned as borrowed `ByteSlice` (no String allocation).
///
/// On the host runtime, differential tests compare `WireDecodable` output
/// against the existing `Codable` path (`PayloadCoder.decode`) to prove
/// semantic equivalence before production cutover.
public protocol WireDecodable {
    /// Creates an instance by decoding fields from `reader`.
    ///
    /// - Parameter reader: A ``WireReader`` over the JSON payload bytes.
    /// - Throws: ``WireDecodeError`` if a required field is missing or malformed.
    init(from reader: WireReader) throws(WireDecodeError)
}

/// Foundation-free encode protocol for wire types.
///
/// Types conforming to `WireEncodable` encode into a caller-provided
/// `WireWriter` buffer without `Codable` or `Foundation`. The writer
/// writes JSON directly into a fixed-size byte buffer with overflow
/// protection.
public protocol WireEncodable {
    /// Encodes this value into the given writer's buffer as JSON.
    ///
    /// - Parameter writer: The ``WireWriter`` to encode into.
    /// - Throws: ``WireEncodeError`` if the encoded output exceeds the buffer capacity.
    func encode(to writer: inout WireWriter) throws(WireEncodeError)
}
