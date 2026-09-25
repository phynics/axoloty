// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

/// Test-time reflection for the borrowed wire views (ST-0022).
extension ByteSlice: CustomTestReflectable {
    /// A bounded hex and text description for test-failure output.
    public var customTestMirror: Mirror {
        let bytes = ownedBytes()
        return Mirror(self, children: [
            "length": bytes.count,
            "hex": RootWireTestReflection.hex(bytes),
            "text": RootWireTestReflection.text(bytes),
        ], displayStyle: .struct)
    }
}

extension TopicView: CustomTestReflectable {
    /// A bounded topic description for test-failure output.
    public var customTestMirror: Mirror {
        Mirror(self, children: [
            "levelCount": levelCount,
            "text": RootWireTestReflection.text(rawBytes.ownedBytes()),
            "namespace": RootWireTestReflection.text(namespaceLevel?.ownedBytes() ?? []),
            "sourceId": RootWireTestReflection.text(sourceIdLevel?.ownedBytes() ?? []),
        ], displayStyle: .struct)
    }
}

private enum RootWireTestReflection {
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

    static func text(_ bytes: [UInt8], limit: Int = 96) -> String {
        let clipped = bytes.count > limit
            ? Array(bytes.prefix(limit)) + Array("...".utf8)
            : bytes
        return String(decoding: clipped, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
}
