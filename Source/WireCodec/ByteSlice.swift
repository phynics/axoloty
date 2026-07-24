// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A borrowed, zero-allocation slice of a byte buffer.
///
/// Holds a raw pointer and length into an externally-owned byte buffer.
/// No String or Array is allocated — callers compare byte slices directly
/// against known patterns (event codes, UUID strings, etc.).
///
/// - Important: The caller must ensure the underlying buffer outlives the
///   `ByteSlice`. This type is intentionally not `Sendable`; it is designed
///   for synchronous dispatch in the routing hot path, not for crossing
///   isolation boundaries.
public struct ByteSlice: Equatable, Hashable {
    @usableFromInline let pointer: UnsafeRawPointer
    public let length: Int

    @inlinable
    init(pointer: UnsafeRawPointer, length: Int) {
        self.pointer = pointer
        self.length = length
    }

    /// Creates a ByteSlice from a contiguous byte buffer pointer.
    @inlinable
    public init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.pointer = UnsafeRawPointer(bytes)
        self.length = length
    }

    /// Compares this slice against a static ASCII string (e.g. `"ADV"`, `"DSC"`).
    @inlinable
    public func equals(_ staticString: StaticString) -> Bool {
        let targetLen = staticString.utf8CodeUnitCount
        guard length == targetLen else { return false }
        for i in 0..<length {
            let byte = pointer.load(fromByteOffset: i, as: UInt8.self)
            if byte != staticString.utf8Start[i] {
                return false
            }
        }
        return true
    }

    /// Returns the byte at the given index, or nil if out of bounds.
    @inlinable
    public func byte(at index: Int) -> UInt8? {
        guard index < length else { return nil }
        return pointer.load(fromByteOffset: index, as: UInt8.self)
    }

    /// Returns a sub-slice of this slice.
    @inlinable
    public func subSlice(from start: Int, length len: Int) -> ByteSlice {
        ByteSlice(pointer: pointer.advanced(by: start), length: len)
    }

    /// Iterates over the bytes in this slice.
    @inlinable
    public func withBytes<R>(_ body: (UnsafeRawPointer, Int) -> R) -> R {
        body(pointer, length)
    }

    /// Converts this byte slice to a `String` by copying the bytes.
    ///
    /// - Returns: The UTF-8 string representation of this slice.
    public func asString() -> String {
        let buf = UnsafeBufferPointer(
            start: pointer.assumingMemoryBound(to: UInt8.self),
            count: length
        )
        return String(decoding: buf, as: UTF8.self)
    }

    /// Compares this slice against an ASCII string's UTF-8 bytes.
    public static func == (lhs: ByteSlice, rhs: ByteSlice) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for i in 0..<lhs.length {
            let a = lhs.pointer.load(fromByteOffset: i, as: UInt8.self)
            let b = rhs.pointer.load(fromByteOffset: i, as: UInt8.self)
            if a != b { return false }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        for i in 0..<length {
            hasher.combine(pointer.load(fromByteOffset: i, as: UInt8.self))
        }
    }
}
