// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A borrowed, zero-allocation slice of a byte buffer.
///
/// Holds a raw pointer and length into an externally-owned byte buffer.
/// No String or Array is allocated — callers compare byte slices directly
/// against known patterns (event codes, UUID strings, etc.).
///
/// - Important: The caller must ensure the underlying buffer outlives the
///   `ByteSlice`. When derived from ``BorrowedMessage``, use it only in that
///   message's synchronous borrow scope. Copy needed bytes before an `await`,
///   creating a `Task`, crossing an actor or other isolation-domain hop, or
///   entering an escaping closure/`AsyncStream`. This type is intentionally
///   not `Sendable`.
public struct ByteSlice: Equatable, Hashable {
    /// The raw pointer into the externally-owned byte buffer.
    @usableFromInline let pointer: UnsafeRawPointer
    /// The number of bytes in this slice.
    public let length: Int

    /// Creates a slice borrowing the given pointer and length.
    ///
    /// - Parameters:
    ///   - pointer: A pointer into an externally-owned byte buffer.
    ///   - length: The number of bytes in the slice.
    @inlinable
    init(pointer: UnsafeRawPointer, length: Int) {
        self.pointer = pointer
        self.length = length
    }

    /// Creates a ByteSlice from a contiguous byte buffer pointer.
    @inlinable
    public init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.pointer = UnsafeRawPointer(bytes)
        self.length = max(0, length)
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
        guard index >= 0, index < length else { return nil }
        return pointer.load(fromByteOffset: index, as: UInt8.self)
    }

    /// Returns a sub-slice of this slice.
    @inlinable
    public func subSlice(from start: Int, length len: Int) -> ByteSlice {
        guard start >= 0, len >= 0, start <= self.length, len <= self.length - start else {
            return ByteSlice(pointer: pointer, length: 0)
        }
        return ByteSlice(pointer: pointer.advanced(by: start), length: len)
    }

    /// Iterates over the bytes in this slice.
    @inlinable
    public func withBytes<R>(_ body: (UnsafeRawPointer, Int) -> R) -> R {
        body(pointer, length)
    }

    #if !hasFeature(Embedded)
    /// Converts this byte slice to a `String` by copying the bytes.
    ///
    /// - Returns: The UTF-8 string representation of this slice.
    ///
    /// - Note: Unavailable in Embedded Swift to avoid pulling in the
    ///   Unicode normalization runtime. Use byte-level comparison
    ///   (``equals(_:)``) instead.
    public func asString() -> String {
        let buf = UnsafeBufferPointer(
            start: pointer.assumingMemoryBound(to: UInt8.self),
            count: length
        )
        return String(decoding: buf, as: Unicode.UTF8.self)
    }
    #endif

    /// Returns `true` if both slices have the same length and byte contents.
    public static func == (lhs: ByteSlice, rhs: ByteSlice) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for i in 0..<lhs.length {
            let a = lhs.pointer.load(fromByteOffset: i, as: UInt8.self)
            let b = rhs.pointer.load(fromByteOffset: i, as: UInt8.self)
            if a != b { return false }
        }
        return true
    }

    /// Feeds each byte into `hasher` so ``ByteSlice`` can be used as a
    /// `Set` or `Dictionary` key.
    public func hash(into hasher: inout Hasher) {
        for i in 0..<length {
            hasher.combine(pointer.load(fromByteOffset: i, as: UInt8.self))
        }
    }
}
