// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

/// Test-time reflection for the borrowed wire views (ST-0022).
///
/// Swift Testing builds a `Mirror` for the operands of a failed expectation.
/// The default breakdown of a pointer-backed view shows an address and a
/// length. These conformances replace that with a bounded hex and text view,
/// so a failing `#expect(slice == expected)` shows the bytes.
extension ByteSlice: CustomTestReflectable {
    /// A bounded hex and text description for test-failure output.
    public var customTestMirror: Mirror {
        let bytes = ownedBytes()
        return Mirror(self, children: [
            "length": bytes.count,
            "hex": WireTestReflection.hex(bytes),
            "text": WireTestReflection.text(bytes),
        ], displayStyle: .struct)
    }
}

extension TopicView: CustomTestReflectable {
    /// A bounded topic description for test-failure output.
    public var customTestMirror: Mirror {
        Mirror(self, children: [
            "levelCount": levelCount,
            "text": WireTestReflection.text(rawBytes.ownedBytes()),
            "namespace": WireTestReflection.text(namespaceLevel?.ownedBytes() ?? []),
            "sourceId": WireTestReflection.text(sourceIdLevel?.ownedBytes() ?? []),
        ], displayStyle: .struct)
    }
}

/// Shared formatting for the wire-value test mirrors.
enum WireTestReflection {
    /// Formats up to `limit` bytes as lowercase hex pairs separated by spaces.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to format.
    ///   - limit: The maximum number of bytes to show.
    /// - Returns: A hex string, with a truncation marker when clipped.
    static func hex(_ bytes: [UInt8], limit: Int = 64) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(Swift.min(bytes.count, limit) * 3)
        for (index, byte) in bytes.prefix(limit).enumerated() {
            if index > 0 { output.append(0x20) }
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0F)])
        }
        if bytes.count > limit { output.append(contentsOf: Array(" ...".utf8)) }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes up to `limit` bytes as UTF-8 text.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to decode.
    ///   - limit: The maximum number of bytes to decode.
    /// - Returns: The decoded text, with a truncation marker when clipped.
    static func text(_ bytes: [UInt8], limit: Int = 96) -> String {
        let clipped = bytes.count > limit
            ? Array(bytes.prefix(limit)) + Array("...".utf8)
            : bytes
        return String(decoding: clipped, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
}
