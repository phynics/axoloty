// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A bounded, owned CBOR object map that preserves its exact encoded bytes.
///
/// This representation is for `axoloty/1` object payloads. It does not expose
/// JSON views or translate CBOR values into JSON. Known fields can be decoded
/// through the shared ``WireCodec`` reader, while unknown values remain
/// available as their original CBOR slices.
///
/// The shared CBOR reader indexes at most 24 top-level fields. A map with more
/// fields fails with ``ObjectError/Reason/fieldIndexOverflow`` regardless of
/// `fieldCapacity`, so values above 24 never admit a larger map.
public struct BoundedCBORObject<let byteCapacity: Int, let fieldCapacity: Int>: ~Copyable, Sendable {
    private var storage: InlineArray<byteCapacity, UInt8>
    private let length: Int
    private let fieldCount: Int

    /// Copies and validates one complete deterministic CBOR map.
    ///
    /// - Parameter bytes: A borrowed slice containing one CBOR map.
    /// - Throws: ``ObjectError`` when the input is malformed, exceeds either
    ///   fixed capacity, or is not a map.
    public init(decoding bytes: ByteSlice) throws(ObjectError) {
        guard bytes.length > 0 else {
            throw ObjectError(.invalidObject)
        }
        guard bytes.length <= byteCapacity else {
            throw ObjectError(.capacityExceeded, byteOffset: bytes.length)
        }

        var nextStorage = InlineArray<byteCapacity, UInt8>(repeating: 0)
        var nextFieldCount = 0
        var failure: ObjectError?
        bytes.withBytes { pointer, count in
            for index in 0..<count {
                nextStorage[index] = pointer.load(fromByteOffset: index, as: UInt8.self)
            }

            withUnsafeBytes(of: nextStorage) { buffer in
                let codec = WireCodec(profile: .axoloty1CBOR)
                let reader = codec.reader(
                    bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    length: count
                )
                do throws(WireDecodeError) {
                    try reader.validate()
                    try reader.withObjectFields { field in
                        guard failure == nil else { return }
                        nextFieldCount += 1
                        if nextFieldCount > fieldCapacity {
                            failure = ObjectError(.capacityExceeded, byteOffset: field.keyRange.lowerBound)
                        }
                    }
                } catch {
                    failure = objectError(error)
                }
            }
        }
        if let failure { throw failure }
        self.storage = nextStorage
        self.length = bytes.length
        self.fieldCount = nextFieldCount
    }

    /// The number of top-level fields in the owned CBOR map.
    public var count: Int { fieldCount }

    /// Borrows the complete canonical CBOR map for the duration of `body`.
    ///
    /// - Parameter body: A synchronous operation receiving the borrowed bytes.
    /// - Returns: The result of `body`.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try withStorageBytes { pointer in
            try body(ByteSlice(
                bytes: pointer.assumingMemoryBound(to: UInt8.self),
                length: length
            ))
        }
    }

    /// Borrows one field's complete encoded CBOR value when the text key exists.
    ///
    /// - Parameters:
    ///   - key: A text key in the top-level CBOR map.
    ///   - body: A synchronous operation receiving the exact encoded value.
    /// - Returns: `true` when the field exists, otherwise `false`.
    public borrowing func withValue(
        for key: StaticString,
        _ body: (borrowing ByteSlice) -> Void
    ) -> Bool {
        withStorageBytes { pointer in
            let codec = WireCodec(profile: .axoloty1CBOR)
            let reader = codec.reader(
                bytes: pointer.assumingMemoryBound(to: UInt8.self),
                length: length
            )
            guard let value = reader.readField(key) else { return false }
            body(value)
            return true
        }
    }

    private func withStorageBytes<R>(
        _ body: (UnsafeRawPointer) throws -> R
    ) rethrows -> R {
        try withUnsafeBytes(of: storage) { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private func objectError(_ error: WireDecodeError) -> ObjectError {
    if case .fieldIndexOverflow = error.reason {
        return ObjectError(.fieldIndexOverflow, byteOffset: error.byteOffset)
    }
    return ObjectError(.invalidObject, byteOffset: error.byteOffset)
}
