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

    /// An empty slice with a non-dereferenceable sentinel pointer.
    ///
    /// Operations on an empty slice never read the pointer. This value lets
    /// bounded protocol adapters represent a valid zero-length binary
    /// payload without allocating temporary storage.
    public static var empty: Self {
        Self(pointer: UnsafeRawPointer(bitPattern: 1)!, length: 0)
    }

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

    /// Compares JSON string content using escape-aware scalar semantics.
    public func semanticEquals(_ staticString: StaticString) -> Bool {
        withBytes { pointer, count in
            var first = WireKeyCursor(bytes: pointer, range: 0..<count, decodesEscapes: true)
            var second = WireKeyCursor(key: staticString)
            return wireSemanticKeysEqual(&first, &second)
        }
    }

    /// Compares two JSON string contents using escape-aware scalar semantics.
    public func semanticEquals(_ other: ByteSlice) -> Bool {
        withBytes { firstPointer, firstCount in
            other.withBytes { secondPointer, secondCount in
                var first = WireKeyCursor(bytes: firstPointer, range: 0..<firstCount, decodesEscapes: true)
                var second = WireKeyCursor(bytes: secondPointer, range: 0..<secondCount, decodesEscapes: true)
                return wireSemanticKeysEqual(&first, &second)
            }
        }
    }

    /// Copies JSON string-content bytes after interpreting escapes into a
    /// caller-owned fixed buffer.
    ///
    /// The slice must contain string content without the surrounding quote
    /// characters. This is the boundary used by wire DTO readers, which
    /// retain encoded content so field matching can remain allocation-free.
    /// The returned bytes are the semantic UTF-8 spelling, not the encoded
    /// JSON spelling.
    ///
    /// - Parameters:
    ///   - output: Fixed storage receiving the decoded UTF-8 bytes.
    /// - Returns: The number of decoded bytes written.
    /// - Throws: ``WireDecodeError`` for malformed escapes or capacity
    ///   exhaustion.
    public borrowing func copyDecodedJSONString<let capacity: Int>(
        into output: inout InlineArray<capacity, UInt8>
    ) throws(WireDecodeError) -> Int {
        var count = 0
        var overflow = false
        var decodingFailure: WireDecodeError?
        withBytes { pointer, length in
            let view = WireValueView(
                bytes: pointer.assumingMemoryBound(to: UInt8.self),
                length: length
            )
            do throws(WireDecodeError) {
                try view.withDecodedScalars(in: 0..<length) { scalar in
                guard !overflow else { return }
                let width: Int
                if scalar <= 0x7F { width = 1 }
                else if scalar <= 0x7FF { width = 2 }
                else if scalar <= 0xFFFF { width = 3 }
                else { width = 4 }
                guard count <= capacity - width else {
                    overflow = true
                    return
                }
                switch width {
                case 1:
                    output[count] = UInt8(scalar)
                case 2:
                    output[count] = UInt8(0xC0 | (scalar >> 6))
                    output[count + 1] = UInt8(0x80 | (scalar & 0x3F))
                case 3:
                    output[count] = UInt8(0xE0 | (scalar >> 12))
                    output[count + 1] = UInt8(0x80 | ((scalar >> 6) & 0x3F))
                    output[count + 2] = UInt8(0x80 | (scalar & 0x3F))
                default:
                    output[count] = UInt8(0xF0 | (scalar >> 18))
                    output[count + 1] = UInt8(0x80 | ((scalar >> 12) & 0x3F))
                    output[count + 2] = UInt8(0x80 | ((scalar >> 6) & 0x3F))
                    output[count + 3] = UInt8(0x80 | (scalar & 0x3F))
                }
                count += width
            }
            } catch {
                decodingFailure = error
            }
        }
        if let decodingFailure { throw decodingFailure }
        guard !overflow else {
            throw WireDecodeError(.payloadExceedsLimit, byteOffset: count)
        }
        return count
    }

    /// Returns the index of the first occurrence of `target`, or nil if absent.
    ///
    /// This is distinct from the slicing `findByte(_:)` helper used by topic
    /// parsing, which returns the sub-slice *after* the matched byte.
    @inlinable
    public func findByteIndex(_ target: UInt8) -> Int? {
        for i in 0..<length where pointer.load(fromByteOffset: i, as: UInt8.self) == target {
            return i
        }
        return nil
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

extension ByteSlice {
    /// Runs a synchronous callback with a noncopyable view of this value.
    public func withBorrowedWireValue(_ body: (borrowing WireValueView) -> Void) {
        withBytes { pointer, count in
            let reader = WireValueReader(bytes: pointer, length: count)
            reader.withBorrowedValue(body)
        }
    }

    /// Borrows direct array elements without exposing the tokenizer reader.
    public func withBorrowedArrayElements(
        _ body: (borrowing WireValueView) -> Void
    ) throws(WireDecodeError) {
        var failure: WireDecodeError?
        withBytes { pointer, count in
            let reader = WireValueReader(bytes: pointer, length: count)
            do throws(WireDecodeError) { try reader.withBorrowedArrayElements(body) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Borrows direct object fields without exposing the tokenizer reader.
    public func withBorrowedObjectFields(
        _ body: (borrowing WireObjectField) -> Void
    ) throws(WireDecodeError) {
        var failure: WireDecodeError?
        withBytes { pointer, count in
            let reader = WireValueReader(bytes: pointer, length: count)
            do throws(WireDecodeError) { try reader.withObjectFields(body) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Visits decoded Unicode scalars through the compatibility wire seam.
    public func withStringScalars(_ body: (UInt32) -> Void) throws(WireDecodeError) {
        var failure: WireDecodeError?
        withBytes { pointer, count in
            let reader = WireValueReader(bytes: pointer, length: count)
            do throws(WireDecodeError) { try reader.withStringScalars(body) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Borrows direct array elements through the copyable compatibility seam.
    public func withArrayElements(_ body: (ByteSlice) -> Void) throws(WireDecodeError) {
        var failure: WireDecodeError?
        withBytes { pointer, count in
            let reader = WireValueReader(bytes: pointer, length: count)
            do throws(WireDecodeError) { try reader.withArrayElements(body) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Borrows direct object fields through the copyable compatibility seam.
    public func withObjectFields(_ body: (borrowing WireObjectField) -> Void) throws(WireDecodeError) {
        try withBorrowedObjectFields(body)
    }

    /// The lexical kind of this complete JSON value.
    public var wireValueKind: WireValueKind {
        guard let byte = byte(at: 0) else { return .invalid }
        switch byte {
        case 0x7B: return .object
        case 0x5B: return .array
        case 0x22: return .string
        case 0x2D, 0x30...0x39: return .number
        case 0x74: return .trueValue
        case 0x66: return .falseValue
        case 0x6E: return .null
        default: return .invalid
        }
    }
}
