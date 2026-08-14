// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A fixed-size 16-byte UUID that does not depend on Foundation.
///
/// Replaces the class-based `CoatyUUID` (which wraps Foundation `UUID`) in
/// the embedded wire path. Can be parsed from a 36-character hyphenated UUID
/// string (as bytes) without allocating a String.
public struct UUID16: Equatable, Hashable, Sendable {
    /// The 16 raw bytes of the UUID.
    public let bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    /// Returns `true` if the two UUIDs have identical byte sequences.
    public static func == (lhs: UUID16, rhs: UUID16) -> Bool {
        lhs.bytes.0 == rhs.bytes.0 && lhs.bytes.1 == rhs.bytes.1 &&
        lhs.bytes.2 == rhs.bytes.2 && lhs.bytes.3 == rhs.bytes.3 &&
        lhs.bytes.4 == rhs.bytes.4 && lhs.bytes.5 == rhs.bytes.5 &&
        lhs.bytes.6 == rhs.bytes.6 && lhs.bytes.7 == rhs.bytes.7 &&
        lhs.bytes.8 == rhs.bytes.8 && lhs.bytes.9 == rhs.bytes.9 &&
        lhs.bytes.10 == rhs.bytes.10 && lhs.bytes.11 == rhs.bytes.11 &&
        lhs.bytes.12 == rhs.bytes.12 && lhs.bytes.13 == rhs.bytes.13 &&
        lhs.bytes.14 == rhs.bytes.14 && lhs.bytes.15 == rhs.bytes.15
    }

    /// Feeds all 16 bytes into `hasher` so ``UUID16`` can be used as a
    /// `Set` or `Dictionary` key.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes.0)
        hasher.combine(bytes.1)
        hasher.combine(bytes.2)
        hasher.combine(bytes.3)
        hasher.combine(bytes.4)
        hasher.combine(bytes.5)
        hasher.combine(bytes.6)
        hasher.combine(bytes.7)
        hasher.combine(bytes.8)
        hasher.combine(bytes.9)
        hasher.combine(bytes.10)
        hasher.combine(bytes.11)
        hasher.combine(bytes.12)
        hasher.combine(bytes.13)
        hasher.combine(bytes.14)
        hasher.combine(bytes.15)
    }

    /// Creates a UUID from its 16 raw bytes.
    ///
    /// - Parameter bytes: The 16 bytes of the UUID.
    public init(bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )) {
        self.bytes = bytes
    }

    /// Parses a UUID from a 36-byte hyphenated ASCII representation
    /// (e.g. `33333333-3333-4333-8333-333333333333`).
    ///
    /// Returns nil if the input is not a valid UUID string.
    public init?(parsing ascii: ByteSlice) {
        guard ascii.length == 36 else { return nil }
        guard let raw = Self.parseASCII({ ascii.byte(at: $0) }) else { return nil }
        self.init(bytes: raw)
    }

    #if !hasFeature(Embedded)
    /// Convenience init from a Swift String (host path only).
    ///
    /// - Note: Unavailable in Embedded Swift to avoid pulling in the
    ///   Unicode normalization runtime. Use ``init?(parsing:)`` with a
    ///   ``ByteSlice`` for byte-level parsing in Embedded builds.
    public init?(parsing string: String) {
        let utf8 = Array(string.utf8)
        guard utf8.count == 36 else { return nil }
        guard let raw = Self.parseASCII({ index in
            index < utf8.count ? utf8[index] : nil
        }) else { return nil }
        self.init(bytes: raw)
    }
    #endif

    private typealias Storage = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private static func parseASCII(_ byteAt: (Int) -> UInt8?) -> Storage? {
        var raw: Storage = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var index = 0
        var byteOffset = 0
        while byteOffset < 36 {
            if isUUIDSeparator(byteOffset) {
                guard byteAt(byteOffset) == 0x2D else { return nil }
                byteOffset += 1
                continue
            }
            guard let high = byteAt(byteOffset).flatMap(hexDigit),
                  let low = byteAt(byteOffset + 1).flatMap(hexDigit),
                  store((high << 4) | low, at: index, in: &raw) else { return nil }
            index += 1
            byteOffset += 2
        }
        return index == 16 ? raw : nil
    }

    private static func isUUIDSeparator(_ offset: Int) -> Bool {
        offset == 8 || offset == 13 || offset == 18 || offset == 23
    }

    private static func store(_ byte: UInt8, at index: Int, in storage: inout Storage) -> Bool {
        guard index < 16 else { return false }
        withUnsafeMutableBytes(of: &storage) { bytes in
            bytes[index] = byte
        }
        return true
    }

    @inline(__always)
    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30 // 0-9
        case 0x41...0x46: return byte - 0x41 + 10 // A-F
        case 0x61...0x66: return byte - 0x61 + 10 // a-f
        default: return nil
        }
    }

    /// Returns the nil UUID (all zeros).
    public static let zero = UUID16(bytes: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}
