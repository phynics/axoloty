// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

private typealias ZenohKeyBytes = InlineArray<256, UInt8>
private typealias ZenohPayloadBytes = InlineArray<2048, UInt8>

/// Fixed-inline receive storage sized to the C façade's maximum frame.
///
/// This value owns no heap allocation. Its key and payload views are borrowed
/// only for the duration of their respective `with...Bytes` calls.
public struct ZenohFrameStorage {
    /// Maximum key-expression length supported by the façade, in bytes.
    public static let keyCapacity = 256
    /// Maximum publication payload length supported by the façade, in bytes.
    public static let payloadCapacity = 2048

    private var keyStorage: ZenohKeyBytes
    private var payloadStorage: ZenohPayloadBytes
    private var keyLength: Int
    private var payloadLength: Int

    /// Creates empty fixed-inline frame storage.
    public init() {
        keyStorage = InlineArray(repeating: 0)
        payloadStorage = InlineArray(repeating: 0)
        keyLength = 0
        payloadLength = 0
    }

    /// The number of key bytes in the last successfully polled frame.
    public var storedKeyLength: Int { keyLength }

    /// The number of payload bytes in the last successfully polled frame.
    public var storedPayloadLength: Int { payloadLength }

    /// Borrows the last polled key bytes for a synchronous operation.
    ///
    /// - Parameter body: A closure that reads the borrowed key bytes.
    /// - Returns: The closure's result.
    public func withKeyBytes<R>(_ body: (ByteSlice) -> R) -> R {
        withUnsafeBytes(of: keyStorage) { raw in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return body(ByteSlice(bytes: pointer, length: keyLength))
        }
    }

    /// Borrows the last polled payload bytes for a synchronous operation.
    ///
    /// - Parameter body: A closure that reads the borrowed payload bytes.
    /// - Returns: The closure's result.
    public func withPayloadBytes<R>(_ body: (ByteSlice) -> R) -> R {
        withUnsafeBytes(of: payloadStorage) { raw in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return body(ByteSlice(bytes: pointer, length: payloadLength))
        }
    }

    mutating func withMutableBuffers<R>(
        _ body: (UnsafeMutableBufferPointer<UInt8>, UnsafeMutableBufferPointer<UInt8>) -> R
    ) -> R {
        withUnsafeMutableBytes(of: &keyStorage) { keyRaw in
            withUnsafeMutableBytes(of: &payloadStorage) { payloadRaw in
                let keyBuffer = UnsafeMutableBufferPointer(
                    start: keyRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    count: keyRaw.count
                )
                let payloadBuffer = UnsafeMutableBufferPointer(
                    start: payloadRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    count: payloadRaw.count
                )
                keyLength = 0
                payloadLength = 0
                return body(keyBuffer, payloadBuffer)
            }
        }
    }

    mutating func setLengths(key: Int, payload: Int) {
        keyLength = key
        payloadLength = payload
    }
}
